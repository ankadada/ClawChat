#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <jni.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <mutex>
#include <memory>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0)
#endif

namespace {

constexpr size_t kChunkSize = 64U * 1024U;
constexpr size_t kJournalMaxBytes = 2048U;
constexpr size_t kReconcileWorkLimit = 64U;
constexpr size_t kJournalLockShardCount = 64U;
constexpr size_t kCorruptEvidenceSlotBytes = 256U;
constexpr size_t kCorruptEvidenceFileBytes = 2U * kCorruptEvidenceSlotBytes;
constexpr auto kJournalScanBudget = std::chrono::milliseconds(50);
constexpr const char* kJournalPrefix = ".clawchat-import-";
constexpr const char* kJournalSuffix = ".journal";
constexpr const char* kJournalNextSuffix = ".journal.next";
constexpr const char* kJournalDirectory = ".clawchat-import-journals";

std::mutex g_cancel_mutex;
std::mutex g_journal_scan_mutex;
std::array<std::mutex, kJournalLockShardCount> g_journal_mutexes;
std::unordered_set<std::string> g_cancelled;
std::unordered_set<std::string> g_finish_requested;
std::unordered_map<std::string, size_t> g_active_operations;
std::unordered_map<std::string, long> g_reconcile_offsets;
std::unordered_map<std::string, long> g_pending_list_offsets;

class OperationLease {
public:
    explicit OperationLease(std::string operation_id)
        : operation_id_(std::move(operation_id)) {
        std::lock_guard<std::mutex> lock(g_cancel_mutex);
        ++g_active_operations[operation_id_];
    }
    ~OperationLease() {
        std::lock_guard<std::mutex> lock(g_cancel_mutex);
        auto active = g_active_operations.find(operation_id_);
        if (active != g_active_operations.end() && --active->second == 0U) {
            g_active_operations.erase(active);
            if (g_finish_requested.erase(operation_id_) > 0U) {
                g_cancelled.erase(operation_id_);
            }
        }
    }
    OperationLease(const OperationLease&) = delete;
    OperationLease& operator=(const OperationLease&) = delete;

private:
    std::string operation_id_;
};

class ScopedFd {
public:
    explicit ScopedFd(int fd = -1) : fd_(fd) {}
    ~ScopedFd() { reset(); }
    ScopedFd(const ScopedFd&) = delete;
    ScopedFd& operator=(const ScopedFd&) = delete;
    ScopedFd(ScopedFd&& other) noexcept : fd_(other.fd_) { other.fd_ = -1; }
    ScopedFd& operator=(ScopedFd&& other) noexcept {
        if (this != &other) {
            reset();
            fd_ = other.fd_;
            other.fd_ = -1;
        }
        return *this;
    }
    int get() const { return fd_; }
    bool valid() const { return fd_ >= 0; }
    bool close_checked(int* error = nullptr) {
        if (fd_ < 0) return true;
        const int closing = fd_;
        fd_ = -1;
        if (close(closing) == 0) return true;
        if (error != nullptr) *error = errno;
        return false;
    }
    void reset(int replacement = -1) {
        if (fd_ >= 0) close(fd_);
        fd_ = replacement;
    }

private:
    int fd_;
};

class Utf8Chars {
public:
    Utf8Chars(JNIEnv* env, jstring value) : env_(env), value_(value) {
        if (value_ == nullptr) throw std::invalid_argument("missing argument");
        const jsize length = env_->GetStringLength(value_);
        chars_ = env_->GetStringChars(value_, nullptr);
        if (chars_ == nullptr) throw std::bad_alloc();
        try {
            output_.reserve(static_cast<size_t>(length) * 3U);
            for (jsize index = 0; index < length; ++index) {
                uint32_t code_point = chars_[index];
                if (code_point >= 0xd800U && code_point <= 0xdbffU) {
                    if (++index >= length) throw std::invalid_argument("invalid UTF-16 path");
                    const uint32_t low = chars_[index];
                    if (low < 0xdc00U || low > 0xdfffU) {
                        throw std::invalid_argument("invalid UTF-16 path");
                    }
                    code_point = 0x10000U + ((code_point - 0xd800U) << 10U) +
                        (low - 0xdc00U);
                } else if (code_point >= 0xdc00U && code_point <= 0xdfffU) {
                    throw std::invalid_argument("invalid UTF-16 path");
                }
                append_utf8(code_point);
            }
        } catch (...) {
            env_->ReleaseStringChars(value_, chars_);
            chars_ = nullptr;
            throw;
        }
    }
    ~Utf8Chars() {
        if (chars_ != nullptr) env_->ReleaseStringChars(value_, chars_);
    }
    std::string str() const { return output_; }

private:
    void append_utf8(uint32_t code_point) {
        if (code_point == 0U || code_point > 0x10ffffU) {
            throw std::invalid_argument("invalid Unicode path");
        }
        if (code_point <= 0x7fU) {
            output_.push_back(static_cast<char>(code_point));
        } else if (code_point <= 0x7ffU) {
            output_.push_back(static_cast<char>(0xc0U | (code_point >> 6U)));
            output_.push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
        } else if (code_point <= 0xffffU) {
            output_.push_back(static_cast<char>(0xe0U | (code_point >> 12U)));
            output_.push_back(static_cast<char>(0x80U | ((code_point >> 6U) & 0x3fU)));
            output_.push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
        } else {
            output_.push_back(static_cast<char>(0xf0U | (code_point >> 18U)));
            output_.push_back(static_cast<char>(0x80U | ((code_point >> 12U) & 0x3fU)));
            output_.push_back(static_cast<char>(0x80U | ((code_point >> 6U) & 0x3fU)));
            output_.push_back(static_cast<char>(0x80U | (code_point & 0x3fU)));
        }
    }

    JNIEnv* env_;
    jstring value_;
    const jchar* chars_ = nullptr;
    std::string output_;
};

struct RelativeFile {
    ScopedFd parent;
    ScopedFd file;
    struct stat path_before {};
    struct stat descriptor_before {};
    struct stat parent_before {};
    std::string name;
};

void throw_java(JNIEnv* env, const char* class_name, const char* message) {
    if (env->ExceptionCheck()) return;
    jclass type = env->FindClass(class_name);
    if (type != nullptr) env->ThrowNew(type, message);
}

bool is_hex_operation(const std::string& value) {
    if (value.size() != 32U) return false;
    for (char c : value) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

std::mutex& journal_mutex_for(const std::string& operation_id) {
    size_t shard = 0U;
    for (const unsigned char value : operation_id) {
        shard = (shard * 33U + value) % kJournalLockShardCount;
    }
    return g_journal_mutexes[shard];
}

bool is_safe_component(const std::string& value, size_t max_bytes = 255U) {
    if (value.empty() || value.size() > max_bytes || value == "." || value == "..") {
        return false;
    }
    for (char c : value) {
        const bool safe = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (!safe) return false;
    }
    return true;
}

bool cancelled(const std::string& operation_id) {
    std::lock_guard<std::mutex> lock(g_cancel_mutex);
    return g_cancelled.find(operation_id) != g_cancelled.end();
}

bool operation_active(const std::string& operation_id) {
    std::lock_guard<std::mutex> lock(g_cancel_mutex);
    return g_active_operations.find(operation_id) != g_active_operations.end();
}

void require_not_cancelled(const std::string& operation_id) {
    if (cancelled(operation_id)) throw std::runtime_error("operation cancelled");
}

bool regular_single_link(const struct stat& value) {
    return S_ISREG(value.st_mode) && value.st_nlink == 1;
}

bool same_full_snapshot(const struct stat& left, const struct stat& right) {
    return regular_single_link(left) && regular_single_link(right) &&
        left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
        left.st_mode == right.st_mode && left.st_nlink == right.st_nlink &&
        left.st_size == right.st_size &&
        left.st_ctim.tv_sec == right.st_ctim.tv_sec &&
        left.st_ctim.tv_nsec == right.st_ctim.tv_nsec;
}

bool same_directory_identity(const struct stat& left, const struct stat& right) {
    return S_ISDIR(left.st_mode) && S_ISDIR(right.st_mode) &&
        left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
        left.st_mode == right.st_mode && left.st_nlink == right.st_nlink;
}

std::string snapshot_identity(const struct stat& value) {
    return std::to_string(static_cast<unsigned long long>(value.st_dev)) + ":" +
        std::to_string(static_cast<unsigned long long>(value.st_ino)) + ":" +
        std::to_string(static_cast<unsigned long long>(value.st_mode)) + ":" +
        std::to_string(static_cast<unsigned long long>(value.st_nlink)) + ":" +
        std::to_string(static_cast<long long>(value.st_size)) + ":" +
        std::to_string(static_cast<long long>(value.st_ctim.tv_sec)) + ":" +
        std::to_string(static_cast<long long>(value.st_ctim.tv_nsec));
}

ScopedFd open_verified_directory(const std::string& path, struct stat* initial) {
    char resolved[PATH_MAX];
    if (realpath(path.c_str(), resolved) == nullptr || path != resolved) {
        throw std::runtime_error("upload directory is not canonical");
    }
    struct stat path_before {};
    if (lstat(path.c_str(), &path_before) != 0 || !S_ISDIR(path_before.st_mode)) {
        throw std::runtime_error("upload directory is unavailable");
    }
    ScopedFd directory(open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (!directory.valid()) throw std::runtime_error("upload directory open failed");
    struct stat descriptor_before {};
    if (fstat(directory.get(), &descriptor_before) != 0 ||
        path_before.st_dev != descriptor_before.st_dev ||
        path_before.st_ino != descriptor_before.st_ino ||
        path_before.st_mode != descriptor_before.st_mode ||
        path_before.st_nlink != descriptor_before.st_nlink ||
        path_before.st_size != descriptor_before.st_size ||
        path_before.st_ctim.tv_sec != descriptor_before.st_ctim.tv_sec ||
        path_before.st_ctim.tv_nsec != descriptor_before.st_ctim.tv_nsec) {
        throw std::runtime_error("upload directory changed before open");
    }
    *initial = descriptor_before;
    return directory;
}

ScopedFd open_journal_directory(int uploads_fd) {
    if (mkdirat(uploads_fd, kJournalDirectory, 0700) != 0 && errno != EEXIST) {
        throw std::runtime_error("journal namespace create failed");
    }
    struct stat path_before {};
    if (fstatat(
            uploads_fd,
            kJournalDirectory,
            &path_before,
            AT_SYMLINK_NOFOLLOW
        ) != 0 || !S_ISDIR(path_before.st_mode)) {
        throw std::runtime_error("journal namespace preflight failed");
    }
    ScopedFd journal_directory(openat(
        uploads_fd,
        kJournalDirectory,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    ));
    struct stat descriptor {};
    if (!journal_directory.valid() || fstat(journal_directory.get(), &descriptor) != 0 ||
        !same_directory_identity(path_before, descriptor)) {
        throw std::runtime_error("journal namespace identity mismatch");
    }
    if (fsync(uploads_fd) != 0) {
        throw std::runtime_error("journal namespace parent fsync failed");
    }
    return journal_directory;
}

void verify_held_directory(
    int directory_fd,
    const std::string& path,
    const struct stat& initial
) {
    struct stat descriptor_after {};
    struct stat path_after {};
    if (fstat(directory_fd, &descriptor_after) != 0 ||
        lstat(path.c_str(), &path_after) != 0 ||
        !same_directory_identity(initial, descriptor_after) ||
        !same_directory_identity(descriptor_after, path_after)) {
        throw std::runtime_error("upload directory identity changed");
    }
}

std::optional<RelativeFile> open_relative_regular(
    int root_fd,
    const std::string& relative_path
) {
    if (relative_path.empty() || relative_path.size() > 1024U ||
        relative_path.front() == '/') {
        throw std::runtime_error("invalid relative path");
    }
    ScopedFd current(dup(root_fd));
    if (!current.valid()) throw std::runtime_error("root duplication failed");
    size_t offset = 0U;
    while (offset < relative_path.size()) {
        const size_t slash = relative_path.find('/', offset);
        const bool final = slash == std::string::npos;
        const std::string component = final
            ? relative_path.substr(offset)
            : relative_path.substr(offset, slash - offset);
        if (!is_safe_component(component)) {
            throw std::runtime_error("unsafe relative component");
        }
        if (!final) {
            ScopedFd next(openat(
                current.get(),
                component.c_str(),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            ));
            struct stat directory_stat {};
            if (!next.valid() || fstat(next.get(), &directory_stat) != 0 ||
                !S_ISDIR(directory_stat.st_mode)) {
                throw std::runtime_error("unsafe relative directory");
            }
            current = std::move(next);
            offset = slash + 1U;
            continue;
        }
        RelativeFile result;
        result.parent = std::move(current);
        result.name = component;
        if (fstat(result.parent.get(), &result.parent_before) != 0) {
            throw std::runtime_error("relative parent preflight failed");
        }
        errno = 0;
        if (fstatat(
                result.parent.get(),
                result.name.c_str(),
                &result.path_before,
                AT_SYMLINK_NOFOLLOW
            ) != 0) {
            if (errno == ENOENT) return std::nullopt;
            throw std::runtime_error("relative file preflight failed");
        }
        if (!regular_single_link(result.path_before)) {
            throw std::runtime_error("relative file preflight failed");
        }
        result.file.reset(openat(
            result.parent.get(),
            result.name.c_str(),
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        ));
        if (!result.file.valid() ||
            fstat(result.file.get(), &result.descriptor_before) != 0 ||
            !same_full_snapshot(result.path_before, result.descriptor_before)) {
            throw std::runtime_error("relative file snapshot changed");
        }
        return std::optional<RelativeFile>(std::move(result));
    }
    throw std::runtime_error("relative file missing");
}

void write_all(int fd, const uint8_t* data, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        const ssize_t written = write(fd, data + offset, length - offset);
        if (written <= 0) throw std::runtime_error("write failed");
        offset += static_cast<size_t>(written);
    }
}

class Sha256 {
public:
    Sha256() { reset(); }

    void update(const uint8_t* data, size_t length) {
        for (size_t i = 0; i < length; ++i) {
            block_[block_length_++] = data[i];
            if (block_length_ == 64U) {
                transform();
                bit_length_ += 512U;
                block_length_ = 0;
            }
        }
    }

    std::array<uint8_t, 32> finish() {
        const uint64_t total_bits = bit_length_ + block_length_ * 8U;
        block_[block_length_++] = 0x80U;
        if (block_length_ > 56U) {
            while (block_length_ < 64U) block_[block_length_++] = 0U;
            transform();
            block_length_ = 0;
        }
        while (block_length_ < 56U) block_[block_length_++] = 0U;
        for (int shift = 56; shift >= 0; shift -= 8) {
            block_[block_length_++] = static_cast<uint8_t>(total_bits >> shift);
        }
        transform();
        std::array<uint8_t, 32> output {};
        for (size_t i = 0; i < 8U; ++i) {
            output[i * 4U] = static_cast<uint8_t>(state_[i] >> 24U);
            output[i * 4U + 1U] = static_cast<uint8_t>(state_[i] >> 16U);
            output[i * 4U + 2U] = static_cast<uint8_t>(state_[i] >> 8U);
            output[i * 4U + 3U] = static_cast<uint8_t>(state_[i]);
        }
        return output;
    }

private:
    static uint32_t rotate_right(uint32_t value, uint32_t count) {
        return (value >> count) | (value << (32U - count));
    }

    void reset() {
        state_ = {0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
                  0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U};
        block_.fill(0U);
        block_length_ = 0U;
        bit_length_ = 0U;
    }

    void transform() {
        static constexpr std::array<uint32_t, 64> constants = {
            0x428a2f98U,0x71374491U,0xb5c0fbcfU,0xe9b5dba5U,0x3956c25bU,0x59f111f1U,0x923f82a4U,0xab1c5ed5U,
            0xd807aa98U,0x12835b01U,0x243185beU,0x550c7dc3U,0x72be5d74U,0x80deb1feU,0x9bdc06a7U,0xc19bf174U,
            0xe49b69c1U,0xefbe4786U,0x0fc19dc6U,0x240ca1ccU,0x2de92c6fU,0x4a7484aaU,0x5cb0a9dcU,0x76f988daU,
            0x983e5152U,0xa831c66dU,0xb00327c8U,0xbf597fc7U,0xc6e00bf3U,0xd5a79147U,0x06ca6351U,0x14292967U,
            0x27b70a85U,0x2e1b2138U,0x4d2c6dfcU,0x53380d13U,0x650a7354U,0x766a0abbU,0x81c2c92eU,0x92722c85U,
            0xa2bfe8a1U,0xa81a664bU,0xc24b8b70U,0xc76c51a3U,0xd192e819U,0xd6990624U,0xf40e3585U,0x106aa070U,
            0x19a4c116U,0x1e376c08U,0x2748774cU,0x34b0bcb5U,0x391c0cb3U,0x4ed8aa4aU,0x5b9cca4fU,0x682e6ff3U,
            0x748f82eeU,0x78a5636fU,0x84c87814U,0x8cc70208U,0x90befffaU,0xa4506cebU,0xbef9a3f7U,0xc67178f2U};
        std::array<uint32_t, 64> words {};
        for (size_t i = 0; i < 16U; ++i) {
            words[i] = (static_cast<uint32_t>(block_[i * 4U]) << 24U) |
                (static_cast<uint32_t>(block_[i * 4U + 1U]) << 16U) |
                (static_cast<uint32_t>(block_[i * 4U + 2U]) << 8U) |
                static_cast<uint32_t>(block_[i * 4U + 3U]);
        }
        for (size_t i = 16U; i < 64U; ++i) {
            const uint32_t s0 = rotate_right(words[i - 15U], 7U) ^
                rotate_right(words[i - 15U], 18U) ^ (words[i - 15U] >> 3U);
            const uint32_t s1 = rotate_right(words[i - 2U], 17U) ^
                rotate_right(words[i - 2U], 19U) ^ (words[i - 2U] >> 10U);
            words[i] = words[i - 16U] + s0 + words[i - 7U] + s1;
        }
        uint32_t a=state_[0], b=state_[1], c=state_[2], d=state_[3];
        uint32_t e=state_[4], f=state_[5], g=state_[6], h=state_[7];
        for (size_t i = 0; i < 64U; ++i) {
            const uint32_t s1 = rotate_right(e, 6U) ^ rotate_right(e, 11U) ^ rotate_right(e, 25U);
            const uint32_t choice = (e & f) ^ ((~e) & g);
            const uint32_t temp1 = h + s1 + choice + constants[i] + words[i];
            const uint32_t s0 = rotate_right(a, 2U) ^ rotate_right(a, 13U) ^ rotate_right(a, 22U);
            const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
            const uint32_t temp2 = s0 + majority;
            h=g; g=f; f=e; e=d+temp1; d=c; c=b; b=a; a=temp1+temp2;
        }
        state_[0]+=a; state_[1]+=b; state_[2]+=c; state_[3]+=d;
        state_[4]+=e; state_[5]+=f; state_[6]+=g; state_[7]+=h;
    }

    std::array<uint32_t, 8> state_ {};
    std::array<uint8_t, 64> block_ {};
    size_t block_length_ = 0U;
    uint64_t bit_length_ = 0U;
};

std::string hex_digest(const std::array<uint8_t, 32>& digest) {
    static constexpr char alphabet[] = "0123456789abcdef";
    std::string output(64U, '0');
    for (size_t i = 0; i < digest.size(); ++i) {
        output[i * 2U] = alphabet[digest[i] >> 4U];
        output[i * 2U + 1U] = alphabet[digest[i] & 0x0fU];
    }
    return output;
}

std::array<uint8_t, 32> hash_fd(
    int fd,
    uint64_t max_bytes,
    const std::string& operation_id,
    uint64_t* actual
) {
    if (lseek(fd, 0, SEEK_SET) < 0) throw std::runtime_error("seek failed");
    Sha256 digest;
    std::array<uint8_t, kChunkSize> buffer {};
    uint64_t total = 0U;
    while (true) {
        require_not_cancelled(operation_id);
        const ssize_t count = read(fd, buffer.data(), buffer.size());
        if (count < 0) throw std::runtime_error("read failed");
        if (count == 0) break;
        total += static_cast<uint64_t>(count);
        if (total > max_bytes) throw std::runtime_error("bounded read exceeded");
        digest.update(buffer.data(), static_cast<size_t>(count));
    }
    *actual = total;
    return digest.finish();
}

std::string journal_name(const std::string& operation_id) {
    return std::string(kJournalPrefix) + operation_id + kJournalSuffix;
}

std::string journal_next_name(const std::string& operation_id) {
    return std::string(kJournalPrefix) + operation_id + kJournalNextSuffix;
}

std::string journal_evidence_name(const std::string& operation_id) {
    return std::string(kJournalPrefix) + operation_id + ".journal.corrupt.summary";
}

std::string temp_name(const std::string& operation_id) {
    return std::string(kJournalPrefix) + operation_id + ".partial";
}

struct JournalRecord {
    std::string state;
    std::string temporary;
    std::string final_name;
    uint64_t size = 0U;
    std::string sha256 = std::string(64U, '0');
    bool cleanup_final = false;
    std::string error = "none";
};

enum class JournalReadStatus { missing, valid, corrupt };

bool valid_digest(const std::string& value) {
    if (value.size() != 64U) return false;
    for (char c : value) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

bool valid_journal_state(const std::string& value) {
    return value == "PREPARED" || value == "PUBLISHING" ||
        value == "PUBLISHED" || value == "ACKNOWLEDGED" ||
        value == "CLEANUP_REQUIRED";
}

bool valid_error_class(const std::string& value) {
    if (value.empty() || value.size() > 32U) return false;
    for (char c : value) {
        if (!((c >= 'a' && c <= 'z') || c == '_')) return false;
    }
    return true;
}

std::string errno_class(int value) {
    switch (value) {
        case 0: return "none";
        case ENOENT: return "not_found";
        case EACCES:
        case EPERM: return "permission";
        case ENOSPC:
        case EDQUOT: return "no_space";
        case EBUSY: return "busy";
        case EIO: return "io";
        default: return "other";
    }
}

std::string hash_string(const std::string& value) {
    Sha256 digest;
    digest.update(reinterpret_cast<const uint8_t*>(value.data()), value.size());
    return hex_digest(digest.finish());
}

std::string journal_body(const JournalRecord& record) {
    return "state=" + record.state + "\n" +
        "temporary=" + record.temporary + "\n" +
        "final=" + record.final_name + "\n" +
        "size=" + std::to_string(record.size) + "\n" +
        "sha256=" + record.sha256 + "\n" +
        "cleanupFinal=" + (record.cleanup_final ? "1\n" : "0\n") +
        "error=" + record.error + "\n";
}

std::string encode_journal(const JournalRecord& record) {
    const std::string body = journal_body(record);
    return "CLAWCHAT_IMPORT_JOURNAL_V1\nlength=" +
        std::to_string(body.size()) + "\nchecksum=" + hash_string(body) +
        "\n\n" + body;
}

bool take_line(const std::string& value, size_t* offset, std::string* line) {
    const size_t end = value.find('\n', *offset);
    if (end == std::string::npos) return false;
    *line = value.substr(*offset, end - *offset);
    *offset = end + 1U;
    return true;
}

bool parse_u64(const std::string& value, uint64_t* output) {
    if (value.empty() || value.size() > 20U) return false;
    uint64_t result = 0U;
    for (char c : value) {
        if (c < '0' || c > '9') return false;
        const uint64_t digit = static_cast<uint64_t>(c - '0');
        if (result > (UINT64_MAX - digit) / 10U) return false;
        result = result * 10U + digit;
    }
    *output = result;
    return true;
}

bool parse_journal(const std::string& content, JournalRecord* record) {
    size_t offset = 0U;
    std::string line;
    if (!take_line(content, &offset, &line) || line != "CLAWCHAT_IMPORT_JOURNAL_V1") {
        return false;
    }
    if (!take_line(content, &offset, &line) || line.rfind("length=", 0U) != 0U) {
        return false;
    }
    uint64_t body_length = 0U;
    if (!parse_u64(line.substr(7U), &body_length) || body_length > kJournalMaxBytes) {
        return false;
    }
    if (!take_line(content, &offset, &line) || line.rfind("checksum=", 0U) != 0U) {
        return false;
    }
    const std::string checksum = line.substr(9U);
    if (!valid_digest(checksum) || !take_line(content, &offset, &line) || !line.empty()) {
        return false;
    }
    if (content.size() - offset != body_length) return false;
    const std::string body = content.substr(offset);
    if (hash_string(body) != checksum) return false;

    size_t body_offset = 0U;
    auto field = [&](const char* prefix, std::string* output) {
        std::string field_line;
        if (!take_line(body, &body_offset, &field_line) ||
            field_line.rfind(prefix, 0U) != 0U) return false;
        *output = field_line.substr(std::strlen(prefix));
        return true;
    };
    std::string size;
    std::string cleanup_final;
    if (!field("state=", &record->state) ||
        !field("temporary=", &record->temporary) ||
        !field("final=", &record->final_name) ||
        !field("size=", &size) ||
        !field("sha256=", &record->sha256) ||
        !field("cleanupFinal=", &cleanup_final) ||
        !field("error=", &record->error) || body_offset != body.size()) {
        return false;
    }
    if (!parse_u64(size, &record->size) || record->size > 50U * 1024U * 1024U ||
        !valid_journal_state(record->state) ||
        !is_safe_component(record->temporary) ||
        !is_safe_component(record->final_name, 212U) ||
        !valid_digest(record->sha256) || !valid_error_class(record->error) ||
        (cleanup_final != "0" && cleanup_final != "1")) {
        return false;
    }
    record->cleanup_final = cleanup_final == "1";
    const bool has_content_identity = record->sha256 != std::string(64U, '0');
    if ((record->state == "PREPARED" &&
         (record->size != 0U || has_content_identity || record->cleanup_final)) ||
        ((record->state == "PUBLISHING" || record->state == "PUBLISHED" ||
          record->state == "ACKNOWLEDGED") && !has_content_identity) ||
        (record->state != "CLEANUP_REQUIRED" && record->error != "none") ||
        (record->state != "CLEANUP_REQUIRED" && record->cleanup_final)) {
        return false;
    }
    return true;
}

JournalReadStatus read_journal_record(
    int directory_fd,
    const std::string& name,
    JournalRecord* record
) {
    struct stat path_before {};
    errno = 0;
    if (fstatat(directory_fd, name.c_str(), &path_before, AT_SYMLINK_NOFOLLOW) != 0) {
        return errno == ENOENT ? JournalReadStatus::missing : JournalReadStatus::corrupt;
    }
    if (!regular_single_link(path_before) || path_before.st_size <= 0 ||
        static_cast<size_t>(path_before.st_size) > kJournalMaxBytes) {
        return JournalReadStatus::corrupt;
    }
    ScopedFd journal(openat(directory_fd, name.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    struct stat descriptor_before {};
    if (!journal.valid() || fstat(journal.get(), &descriptor_before) != 0 ||
        !same_full_snapshot(path_before, descriptor_before)) {
        return JournalReadStatus::corrupt;
    }
    std::string content(static_cast<size_t>(descriptor_before.st_size), '\0');
    size_t offset = 0U;
    while (offset < content.size()) {
        const ssize_t count = read(journal.get(), content.data() + offset, content.size() - offset);
        if (count <= 0) return JournalReadStatus::corrupt;
        offset += static_cast<size_t>(count);
    }
    struct stat descriptor_after {};
    struct stat path_after {};
    int close_error = 0;
    if (fstat(journal.get(), &descriptor_after) != 0 ||
        fstatat(directory_fd, name.c_str(), &path_after, AT_SYMLINK_NOFOLLOW) != 0 ||
        !same_full_snapshot(descriptor_before, descriptor_after) ||
        !same_full_snapshot(descriptor_after, path_after) ||
        !journal.close_checked(&close_error) || !parse_journal(content, record)) {
        return JournalReadStatus::corrupt;
    }
    return JournalReadStatus::valid;
}

bool journal_filename(const std::string& name) {
    const size_t prefix = std::strlen(kJournalPrefix);
    const size_t suffix = std::strlen(kJournalSuffix);
    if (name.size() != prefix + 32U + suffix || name.compare(0, prefix, kJournalPrefix) != 0 ||
        name.compare(name.size() - suffix, suffix, kJournalSuffix) != 0) {
        return false;
    }
    return is_hex_operation(name.substr(prefix, 32U));
}

bool journal_next_filename(const std::string& name) {
    const size_t prefix = std::strlen(kJournalPrefix);
    const size_t suffix = std::strlen(kJournalNextSuffix);
    if (name.size() != prefix + 32U + suffix || name.compare(0, prefix, kJournalPrefix) != 0 ||
        name.compare(name.size() - suffix, suffix, kJournalNextSuffix) != 0) {
        return false;
    }
    return is_hex_operation(name.substr(prefix, 32U));
}

struct JournalScanBatch {
    std::vector<std::string> operations;
    long next_cookie = 0L;
    size_t read_steps = 0U;
    bool reached_end = false;
};

JournalScanBatch scan_journal_directory_bounded(
    DIR* stream,
    long resume_cookie,
    size_t max_read_steps,
    bool include_replacements,
    const std::string* cancellation_operation
) {
    JournalScanBatch batch;
    batch.next_cookie = resume_cookie;
    std::unordered_set<std::string> seen_operations;
    const auto deadline = std::chrono::steady_clock::now() + kJournalScanBudget;
    while (batch.read_steps < max_read_steps &&
           std::chrono::steady_clock::now() < deadline) {
        if (cancellation_operation != nullptr) {
            require_not_cancelled(*cancellation_operation);
        }
        // Count every readdir attempt before inspecting the name. Junk, dot
        // entries, and EOF all consume the same bounded work budget.
        ++batch.read_steps;
        errno = 0;
        dirent* entry = readdir(stream);
        if (entry == nullptr) {
            if (errno != 0) throw std::runtime_error("journal directory read failed");
            batch.reached_end = true;
            break;
        }
        const long cookie_after_entry = telldir(stream);
        if (cookie_after_entry < 0L) {
            throw std::runtime_error("journal directory cookie failed");
        }
        // Persist the opaque cookie after every consumed entry, including
        // unrecognized attacker-created names. We never sort or restart from
        // lexical order, so inserting lexically earlier junk cannot rewind a
        // live process cursor.
        batch.next_cookie = cookie_after_entry;
        if (cancellation_operation != nullptr) {
            require_not_cancelled(*cancellation_operation);
        }
        const std::string name(entry->d_name);
        if (!journal_filename(name) &&
            !(include_replacements && journal_next_filename(name))) {
            continue;
        }
        const std::string operation_id = name.substr(
            std::strlen(kJournalPrefix), 32U
        );
        if (seen_operations.insert(operation_id).second) {
            batch.operations.push_back(operation_id);
        }
    }
    return batch;
}

void retain_corrupt_journal_evidence_locked(int directory_fd);
int rename_noreplace(int directory_fd, const char* old_name, const char* new_name);

struct CorruptEvidenceSummary {
    uint64_t generation = 0U;
    uint64_t count = 0U;
    std::string chain = std::string(64U, '0');
    int active_slot = -1;
};

std::string encode_corrupt_evidence_slot(const CorruptEvidenceSummary& summary) {
    const std::string body =
        "generation=" + std::to_string(summary.generation) + "\n" +
        "count=" + std::to_string(summary.count) + "\n" +
        "chain=" + summary.chain + "\n";
    std::string encoded =
        "CLAWCHAT_CORRUPT_EVIDENCE_V1\nchecksum=" + hash_string(body) +
        "\n\n" + body;
    if (encoded.size() > kCorruptEvidenceSlotBytes) {
        throw std::runtime_error("corrupt evidence record overflow");
    }
    encoded.resize(kCorruptEvidenceSlotBytes, '\0');
    return encoded;
}

bool parse_corrupt_evidence_slot(
    const std::string& slot,
    CorruptEvidenceSummary* summary
) {
    const size_t content_end = slot.find('\0');
    const std::string content = slot.substr(
        0U, content_end == std::string::npos ? slot.size() : content_end
    );
    size_t offset = 0U;
    std::string line;
    if (!take_line(content, &offset, &line) ||
        line != "CLAWCHAT_CORRUPT_EVIDENCE_V1" ||
        !take_line(content, &offset, &line) ||
        line.rfind("checksum=", 0U) != 0U) {
        return false;
    }
    const std::string checksum = line.substr(9U);
    if (!valid_digest(checksum) || !take_line(content, &offset, &line) ||
        !line.empty()) {
        return false;
    }
    const std::string body = content.substr(offset);
    if (hash_string(body) != checksum) return false;
    size_t body_offset = 0U;
    std::string generation;
    std::string count;
    std::string chain;
    auto field = [&](const char* prefix, std::string* output) {
        std::string field_line;
        if (!take_line(body, &body_offset, &field_line) ||
            field_line.rfind(prefix, 0U) != 0U) return false;
        *output = field_line.substr(std::strlen(prefix));
        return true;
    };
    if (!field("generation=", &generation) || !field("count=", &count) ||
        !field("chain=", &chain) || body_offset != body.size() ||
        !parse_u64(generation, &summary->generation) ||
        !parse_u64(count, &summary->count) || !valid_digest(chain)) {
        return false;
    }
    summary->chain = chain;
    return true;
}

std::string corrupt_next_fingerprint(
    int directory_fd,
    const std::string& next
) {
    struct stat path_before {};
    if (fstatat(directory_fd, next.c_str(), &path_before, AT_SYMLINK_NOFOLLOW) != 0 ||
        !regular_single_link(path_before) || path_before.st_size < 0) {
        throw std::runtime_error("corrupt replacement evidence preflight failed");
    }
    ScopedFd file(openat(directory_fd, next.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    struct stat descriptor_before {};
    if (!file.valid() || fstat(file.get(), &descriptor_before) != 0 ||
        !same_full_snapshot(path_before, descriptor_before)) {
        throw std::runtime_error("corrupt replacement evidence open failed");
    }
    const size_t sample_size = static_cast<size_t>(std::min<off_t>(
        descriptor_before.st_size,
        static_cast<off_t>(kJournalMaxBytes)
    ));
    std::string sample(sample_size, '\0');
    size_t offset = 0U;
    while (offset < sample.size()) {
        const ssize_t count = pread(
            file.get(), sample.data() + offset, sample.size() - offset,
            static_cast<off_t>(offset)
        );
        if (count <= 0) throw std::runtime_error("corrupt replacement evidence read failed");
        offset += static_cast<size_t>(count);
    }
    struct stat descriptor_after {};
    struct stat path_after {};
    int close_error = 0;
    if (fstat(file.get(), &descriptor_after) != 0 ||
        fstatat(directory_fd, next.c_str(), &path_after, AT_SYMLINK_NOFOLLOW) != 0 ||
        !same_full_snapshot(descriptor_before, descriptor_after) ||
        !same_full_snapshot(descriptor_after, path_after) ||
        !file.close_checked(&close_error)) {
        throw std::runtime_error("corrupt replacement evidence changed");
    }
    return std::to_string(static_cast<uint64_t>(descriptor_after.st_size)) + ":" +
        hash_string(sample);
}

void pwrite_all(int fd, const std::string& value, off_t file_offset) {
    size_t offset = 0U;
    while (offset < value.size()) {
        const ssize_t count = pwrite(
            fd, value.data() + offset, value.size() - offset,
            file_offset + static_cast<off_t>(offset)
        );
        if (count <= 0) throw std::runtime_error("corrupt evidence write failed");
        offset += static_cast<size_t>(count);
    }
}

void quarantine_next_locked(int directory_fd, const std::string& operation_id) {
    const std::string next = journal_next_name(operation_id);
    const std::string evidence = journal_evidence_name(operation_id);
    const std::string fingerprint = corrupt_next_fingerprint(directory_fd, next);
    ScopedFd summary(openat(
        directory_fd,
        evidence.c_str(),
        O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
        0600
    ));
    struct stat summary_stat {};
    if (!summary.valid() || fstat(summary.get(), &summary_stat) != 0 ||
        !regular_single_link(summary_stat) || summary_stat.st_size < 0 ||
        static_cast<size_t>(summary_stat.st_size) > kCorruptEvidenceFileBytes) {
        throw std::runtime_error("corrupt evidence summary invalid");
    }
    if (static_cast<size_t>(summary_stat.st_size) < kCorruptEvidenceFileBytes) {
        if (ftruncate(summary.get(), static_cast<off_t>(kCorruptEvidenceFileBytes)) != 0) {
            throw std::runtime_error("corrupt evidence summary allocation failed");
        }
    }
    CorruptEvidenceSummary current;
    std::array<std::string, 2> slots {
        std::string(kCorruptEvidenceSlotBytes, '\0'),
        std::string(kCorruptEvidenceSlotBytes, '\0'),
    };
    for (size_t index = 0U; index < slots.size(); ++index) {
        size_t offset = 0U;
        while (offset < slots[index].size()) {
            const ssize_t count = pread(
                summary.get(),
                slots[index].data() + offset,
                slots[index].size() - offset,
                static_cast<off_t>(index * kCorruptEvidenceSlotBytes + offset)
            );
            if (count <= 0) throw std::runtime_error("corrupt evidence summary read failed");
            offset += static_cast<size_t>(count);
        }
        CorruptEvidenceSummary candidate;
        if (parse_corrupt_evidence_slot(slots[index], &candidate) &&
            (current.active_slot < 0 || candidate.generation > current.generation)) {
            current = candidate;
            current.active_slot = static_cast<int>(index);
        }
    }
    if (current.generation == UINT64_MAX || current.count == UINT64_MAX) {
        throw std::runtime_error("corrupt evidence counter exhausted");
    }
    CorruptEvidenceSummary updated;
    updated.generation = current.generation + 1U;
    updated.count = current.count + 1U;
    updated.chain = hash_string(current.chain + ":" + fingerprint);
    const int target_slot = current.active_slot == 0 ? 1 : 0;
    const std::string encoded_update = encode_corrupt_evidence_slot(updated);
    pwrite_all(
        summary.get(),
        encoded_update,
        static_cast<off_t>(target_slot) * static_cast<off_t>(kCorruptEvidenceSlotBytes)
    );
    if (fsync(summary.get()) != 0) {
        throw std::runtime_error("corrupt evidence summary fsync failed");
    }
    std::string verified_update(kCorruptEvidenceSlotBytes, '\0');
    size_t verified_offset = 0U;
    while (verified_offset < verified_update.size()) {
        const ssize_t count = pread(
            summary.get(),
            verified_update.data() + verified_offset,
            verified_update.size() - verified_offset,
            static_cast<off_t>(target_slot) *
                    static_cast<off_t>(kCorruptEvidenceSlotBytes) +
                static_cast<off_t>(verified_offset)
        );
        if (count <= 0) throw std::runtime_error("corrupt evidence verification read failed");
        verified_offset += static_cast<size_t>(count);
    }
    struct stat summary_after {};
    struct stat summary_path_after {};
    if (verified_update != encoded_update ||
        fstat(summary.get(), &summary_after) != 0 ||
        fstatat(
            directory_fd, evidence.c_str(), &summary_path_after, AT_SYMLINK_NOFOLLOW
        ) != 0 || !same_full_snapshot(summary_after, summary_path_after) ||
        static_cast<size_t>(summary_after.st_size) != kCorruptEvidenceFileBytes) {
        throw std::runtime_error("corrupt evidence verification failed");
    }
    int close_error = 0;
    if (!summary.close_checked(&close_error) || fsync(directory_fd) != 0) {
        throw std::runtime_error("corrupt evidence summary durability failed");
    }
    if (unlinkat(directory_fd, next.c_str(), 0) != 0 && errno != ENOENT) {
        throw std::runtime_error("corrupt replacement removal failed");
    }
    struct stat remaining {};
    errno = 0;
    if (fstatat(directory_fd, next.c_str(), &remaining, AT_SYMLINK_NOFOLLOW) == 0 ||
        errno != ENOENT || fsync(directory_fd) != 0) {
        throw std::runtime_error("corrupt replacement removal not durable");
    }
}

void recover_pending_replacement_locked(int directory_fd, const std::string& operation_id) {
    JournalRecord next_record;
    const std::string next = journal_next_name(operation_id);
    const JournalReadStatus next_status = read_journal_record(directory_fd, next, &next_record);
    if (next_status == JournalReadStatus::missing) return;
    if (next_status == JournalReadStatus::corrupt) {
        quarantine_next_locked(directory_fd, operation_id);
        return;
    }
    JournalRecord live_record;
    const std::string live = journal_name(operation_id);
    const JournalReadStatus live_status = read_journal_record(directory_fd, live, &live_record);
    if (live_status == JournalReadStatus::corrupt) {
        quarantine_next_locked(directory_fd, operation_id);
        return;
    }
    if (renameat(directory_fd, next.c_str(), directory_fd, live.c_str()) != 0 ||
        fsync(directory_fd) != 0) {
        throw std::runtime_error("journal replacement recovery failed");
    }
}

void write_journal_atomic_locked(
    int directory_fd,
    const std::string& operation_id,
    const JournalRecord& record
) {
    recover_pending_replacement_locked(directory_fd, operation_id);
    JournalRecord existing_record;
    if (read_journal_record(
            directory_fd, journal_name(operation_id), &existing_record
        ) == JournalReadStatus::corrupt) {
        retain_corrupt_journal_evidence_locked(directory_fd);
        throw std::runtime_error("corrupt live journal retained");
    }
    const std::string next = journal_next_name(operation_id);
    const std::string content = encode_journal(record);
    ScopedFd replacement(openat(
        directory_fd,
        next.c_str(),
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0600
    ));
    if (!replacement.valid()) throw std::runtime_error("journal replacement create failed");
    write_all(
        replacement.get(),
        reinterpret_cast<const uint8_t*>(content.data()),
        content.size()
    );
    if (fsync(replacement.get()) != 0) throw std::runtime_error("journal replacement fsync failed");
    int close_error = 0;
    if (!replacement.close_checked(&close_error)) {
        throw std::runtime_error("journal replacement close failed");
    }
    const std::string live = journal_name(operation_id);
    if (renameat(directory_fd, next.c_str(), directory_fd, live.c_str()) != 0) {
        throw std::runtime_error("journal atomic rename failed");
    }
    if (fsync(directory_fd) != 0) throw std::runtime_error("journal directory fsync failed");
}

void write_journal_atomic(
    int directory_fd,
    const std::string& operation_id,
    const JournalRecord& record
) {
    std::lock_guard<std::mutex> journal_lock(journal_mutex_for(operation_id));
    write_journal_atomic_locked(directory_fd, operation_id, record);
}

void create_journal_atomic(
    int directory_fd,
    const std::string& operation_id,
    const JournalRecord& record
) {
    std::lock_guard<std::mutex> journal_lock(journal_mutex_for(operation_id));
    recover_pending_replacement_locked(directory_fd, operation_id);
    JournalRecord existing_record;
    if (read_journal_record(
            directory_fd, journal_name(operation_id), &existing_record
        ) != JournalReadStatus::missing) {
        throw std::runtime_error("journal operation id already exists");
    }
    write_journal_atomic_locked(directory_fd, operation_id, record);
}

bool entry_absent(int directory_fd, const std::string& name, int* error) {
    struct stat value {};
    errno = 0;
    if (fstatat(directory_fd, name.c_str(), &value, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) return true;
        if (error != nullptr) *error = errno;
        return false;
    }
    if (error != nullptr) *error = EEXIST;
    return false;
}

bool unlink_and_verify(int directory_fd, const std::string& name, int* error) {
    errno = 0;
    if (unlinkat(directory_fd, name.c_str(), 0) != 0 && errno != ENOENT) {
        if (error != nullptr) *error = errno;
        return false;
    }
    return entry_absent(directory_fd, name, error);
}

bool retain_cleanup_evidence_locked(
    int journal_fd,
    const std::string& operation_id,
    JournalRecord record,
    int error
) {
    record.state = "CLEANUP_REQUIRED";
    record.error = errno_class(error == 0 ? EIO : error);
    try {
        write_journal_atomic_locked(journal_fd, operation_id, record);
        return true;
    } catch (...) {
        // A previous live or replacement record may still be the only durable
        // evidence. Never report cleanup success when refreshing it failed.
        return false;
    }
}

bool cleanup_record_locked(
    int uploads_fd,
    int journal_fd,
    const std::string& operation_id,
    JournalRecord record
) {
    int cleanup_error = 0;
    bool clean = unlink_and_verify(uploads_fd, record.temporary, &cleanup_error);
    if (record.cleanup_final) {
        clean = unlink_and_verify(uploads_fd, record.final_name, &cleanup_error) && clean;
    }
    if (clean && fsync(uploads_fd) != 0) {
        cleanup_error = errno;
        clean = false;
    }
    if (!clean) {
        retain_cleanup_evidence_locked(
            journal_fd, operation_id, record, cleanup_error
        );
        return false;
    }

    const std::string live = journal_name(operation_id);
    if (!unlink_and_verify(journal_fd, live, &cleanup_error)) {
        retain_cleanup_evidence_locked(
            journal_fd, operation_id, record, cleanup_error
        );
        return false;
    }
    if (fsync(journal_fd) != 0) {
        cleanup_error = errno;
        retain_cleanup_evidence_locked(
            journal_fd, operation_id, record, cleanup_error
        );
        return false;
    }
    return true;
}

bool verify_receipt_file(
    int directory_fd,
    const JournalRecord& record,
    const std::string& operation_id
) {
    try {
        ScopedFd file(openat(
            directory_fd,
            record.final_name.c_str(),
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        ));
        struct stat value {};
        if (!file.valid() || fstat(file.get(), &value) != 0 || !regular_single_link(value) ||
            value.st_size < 0 || static_cast<uint64_t>(value.st_size) != record.size) return false;
        uint64_t actual = 0U;
        const std::string digest = hex_digest(
            hash_fd(file.get(), record.size, operation_id, &actual)
        );
        int close_error = 0;
        return actual == record.size && digest == record.sha256 &&
            file.close_checked(&close_error);
    } catch (...) {
        return false;
    }
}

void retain_corrupt_journal_evidence_locked(int directory_fd) {
    // A torn/unparseable live journal is the only ownership evidence. Keep it
    // in place and durably avoid guessing its final target.
    if (fsync(directory_fd) != 0) {
        throw std::runtime_error("corrupt journal evidence fsync failed");
    }
}

void reconcile_directory(
    int uploads_fd,
    int journal_fd,
    const std::string* cancellation_operation = nullptr
) {
    std::vector<std::string> operations;
    {
        std::lock_guard<std::mutex> scan_lock(g_journal_scan_mutex);
        const int duplicate = dup(journal_fd);
        if (duplicate < 0) throw std::runtime_error("directory duplication failed");
        DIR* raw_stream = fdopendir(duplicate);
        if (raw_stream == nullptr) {
            if (close(duplicate) != 0) {
                throw std::runtime_error("directory scan close failed");
            }
            throw std::runtime_error("directory scan failed");
        }
        std::unique_ptr<DIR, decltype(&closedir)> stream(raw_stream, &closedir);
        struct stat directory_identity {};
        if (fstat(journal_fd, &directory_identity) != 0) {
            throw std::runtime_error("reconciliation directory identity failed");
        }
        const std::string cursor_key =
            std::to_string(static_cast<unsigned long long>(directory_identity.st_dev)) + ":" +
            std::to_string(static_cast<unsigned long long>(directory_identity.st_ino));
        const long resume_offset = g_reconcile_offsets[cursor_key];
        if (resume_offset > 0L) seekdir(stream.get(), resume_offset);
        const JournalScanBatch batch = scan_journal_directory_bounded(
            stream.get(),
            resume_offset,
            kReconcileWorkLimit,
            true,
            cancellation_operation
        );
        operations = batch.operations;
        g_reconcile_offsets[cursor_key] =
            batch.reached_end ? 0L : batch.next_cookie;
        if (closedir(stream.release()) != 0) {
            throw std::runtime_error("reconciliation directory close failed");
        }
    }

    for (const std::string& operation_id : operations) {
        if (cancellation_operation != nullptr) {
            require_not_cancelled(*cancellation_operation);
        }
        if (operation_active(operation_id)) continue;
        std::lock_guard<std::mutex> journal_lock(journal_mutex_for(operation_id));
        if (operation_active(operation_id)) continue;
        recover_pending_replacement_locked(journal_fd, operation_id);
        JournalRecord record;
        const JournalReadStatus status = read_journal_record(
            journal_fd, journal_name(operation_id), &record
        );
        if (status == JournalReadStatus::corrupt) {
            retain_corrupt_journal_evidence_locked(journal_fd);
            continue;
        }
        if (status == JournalReadStatus::missing) continue;
        struct stat final_stat {};
        errno = 0;
        const int final_result = fstatat(
            uploads_fd,
            record.final_name.c_str(),
            &final_stat,
            AT_SYMLINK_NOFOLLOW
        );
        if ((final_result == 0 && !regular_single_link(final_stat)) ||
            (final_result != 0 && errno != ENOENT)) {
            continue;
        }
        const bool final_exists = final_result == 0;
        if (record.state == "PREPARED") {
            if (!final_exists) {
                record.state = "CLEANUP_REQUIRED";
                record.cleanup_final = false;
                record.error = "interrupted";
                write_journal_atomic_locked(journal_fd, operation_id, record);
                cleanup_record_locked(uploads_fd, journal_fd, operation_id, record);
            }
        } else if (record.state == "PUBLISHING") {
            if (final_exists && verify_receipt_file(uploads_fd, record, operation_id)) {
                record.state = "PUBLISHED";
                record.error = "none";
                write_journal_atomic_locked(journal_fd, operation_id, record);
            } else if (!final_exists) {
                record.state = "CLEANUP_REQUIRED";
                record.cleanup_final = false;
                record.error = "interrupted";
                write_journal_atomic_locked(journal_fd, operation_id, record);
                cleanup_record_locked(uploads_fd, journal_fd, operation_id, record);
            }
        } else if (record.state == "PUBLISHED") {
            if (!final_exists) {
                record.state = "CLEANUP_REQUIRED";
                record.cleanup_final = false;
                record.error = "not_found";
                write_journal_atomic_locked(journal_fd, operation_id, record);
                cleanup_record_locked(uploads_fd, journal_fd, operation_id, record);
            }
        } else if (record.state == "ACKNOWLEDGED") {
            cleanup_record_locked(uploads_fd, journal_fd, operation_id, record);
        } else if (record.state == "CLEANUP_REQUIRED") {
            cleanup_record_locked(uploads_fd, journal_fd, operation_id, record);
        }
    }
}

int rename_noreplace(int directory_fd, const char* old_name, const char* new_name) {
#ifdef SYS_renameat2
    return static_cast<int>(syscall(
        SYS_renameat2,
        directory_fd,
        old_name,
        directory_fd,
        new_name,
        RENAME_NOREPLACE
    ));
#else
    errno = ENOSYS;
    return -1;
#endif
}

bool cleanup_failed_import(
    int uploads_fd,
    int journal_fd,
    const std::string& operation_id,
    const std::string& temporary,
    const std::string& final_name,
    bool published,
    uint64_t size,
    const std::string& digest,
    int failure_error
) {
    if (uploads_fd < 0 || journal_fd < 0 || !is_hex_operation(operation_id) || temporary.empty() ||
        final_name.empty()) return false;
    std::lock_guard<std::mutex> journal_lock(journal_mutex_for(operation_id));
    JournalRecord record {
        "CLEANUP_REQUIRED",
        temporary,
        final_name,
        size,
        valid_digest(digest) ? digest : std::string(64U, '0'),
        published,
        errno_class(failure_error),
    };
    try {
        write_journal_atomic_locked(journal_fd, operation_id, record);
    } catch (...) {
        // Existing live/next journal is retained as the only cleanup evidence.
    }
    return cleanup_record_locked(uploads_fd, journal_fd, operation_id, record);
}

std::vector<std::string> list_pending_records(
    int journal_fd,
    size_t max_entries
) {
    std::vector<std::string> operations;
    {
        std::lock_guard<std::mutex> scan_lock(g_journal_scan_mutex);
        const int duplicate = dup(journal_fd);
        if (duplicate < 0) {
            throw std::runtime_error("pending list directory duplication failed");
        }
        DIR* raw_stream = fdopendir(duplicate);
        if (raw_stream == nullptr) {
            if (close(duplicate) != 0) {
                throw std::runtime_error("pending list close failed");
            }
            throw std::runtime_error("pending list directory scan failed");
        }
        std::unique_ptr<DIR, decltype(&closedir)> stream(raw_stream, &closedir);
        struct stat directory_identity {};
        if (fstat(journal_fd, &directory_identity) != 0) {
            throw std::runtime_error("pending list directory identity failed");
        }
        const std::string cursor_key =
            std::to_string(static_cast<unsigned long long>(directory_identity.st_dev)) + ":" +
            std::to_string(static_cast<unsigned long long>(directory_identity.st_ino));
        const long resume_offset = g_pending_list_offsets[cursor_key];
        if (resume_offset > 0L) seekdir(stream.get(), resume_offset);
        const JournalScanBatch batch = scan_journal_directory_bounded(
            stream.get(), resume_offset, max_entries, false, nullptr
        );
        operations = batch.operations;
        g_pending_list_offsets[cursor_key] =
            batch.reached_end ? 0L : batch.next_cookie;
        if (closedir(stream.release()) != 0) {
            throw std::runtime_error("pending list directory close failed");
        }
    }

    std::vector<std::string> output;
    for (const std::string& operation_id : operations) {
        if (operation_active(operation_id)) continue;
        std::lock_guard<std::mutex> journal_lock(journal_mutex_for(operation_id));
        if (operation_active(operation_id)) continue;
        recover_pending_replacement_locked(journal_fd, operation_id);
        JournalRecord record;
        const JournalReadStatus status = read_journal_record(
            journal_fd, journal_name(operation_id), &record
        );
        if (status == JournalReadStatus::corrupt) {
            retain_corrupt_journal_evidence_locked(journal_fd);
            continue;
        }
        if (status != JournalReadStatus::valid || record.state != "PUBLISHED") continue;
        output.push_back(
            operation_id + "\n" + record.final_name + "\n" +
            std::to_string(record.size) + "\n" + record.sha256
        );
    }
    return output;
}

jobjectArray string_array(JNIEnv* env, const std::array<std::string, 3>& values) {
    jclass string_class = env->FindClass("java/lang/String");
    if (string_class == nullptr) return nullptr;
    jobjectArray output = env->NewObjectArray(3, string_class, nullptr);
    if (output == nullptr) return nullptr;
    for (jsize i = 0; i < 3; ++i) {
        jstring value = env->NewStringUTF(values[static_cast<size_t>(i)].c_str());
        if (value == nullptr) return nullptr;
        env->SetObjectArrayElement(output, i, value);
        env->DeleteLocalRef(value);
        if (env->ExceptionCheck()) return nullptr;
    }
    return output;
}

jobjectArray string_vector_array(JNIEnv* env, const std::vector<std::string>& values) {
    jclass string_class = env->FindClass("java/lang/String");
    if (string_class == nullptr) return nullptr;
    jobjectArray output = env->NewObjectArray(
        static_cast<jsize>(values.size()), string_class, nullptr
    );
    if (output == nullptr) return nullptr;
    for (jsize index = 0; index < static_cast<jsize>(values.size()); ++index) {
        jstring value = env->NewStringUTF(values[static_cast<size_t>(index)].c_str());
        if (value == nullptr) return nullptr;
        env->SetObjectArrayElement(output, index, value);
        env->DeleteLocalRef(value);
        if (env->ExceptionCheck()) return nullptr;
    }
    return output;
}

}  // namespace

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_anka_clawbot_SecureImportNative_importHostFile(
    JNIEnv* env,
    jobject,
    jstring source_path_value,
    jstring uploads_path_value,
    jstring final_name_value,
    jstring operation_id_value,
    jlong max_bytes_value
) {
    ScopedFd directory;
    ScopedFd journal_directory;
    std::optional<OperationLease> operation;
    std::string temporary;
    std::string final_name;
    std::string operation_id;
    std::string final_digest(64U, '0');
    uint64_t total = 0U;
    bool published = false;
    try {
        const std::string source_path = Utf8Chars(env, source_path_value).str();
        const std::string uploads_path = Utf8Chars(env, uploads_path_value).str();
        final_name = Utf8Chars(env, final_name_value).str();
        operation_id = Utf8Chars(env, operation_id_value).str();
        if (!is_hex_operation(operation_id) || !is_safe_component(final_name, 212U) ||
            max_bytes_value < 0 || max_bytes_value > 50LL * 1024LL * 1024LL) {
            throw std::invalid_argument("invalid import arguments");
        }
        operation.emplace(operation_id);
        require_not_cancelled(operation_id);
        struct stat directory_initial {};
        directory = open_verified_directory(uploads_path, &directory_initial);
        const int directory_fd = directory.get();
        journal_directory = open_journal_directory(directory_fd);
        const int journal_fd = journal_directory.get();
        reconcile_directory(directory_fd, journal_fd, &operation_id);
        temporary = temp_name(operation_id);
        create_journal_atomic(journal_fd, operation_id, JournalRecord {
            "PREPARED", temporary, final_name, 0U, std::string(64U, '0'), false, "none"
        });

        struct stat source_path_before {};
        if (lstat(source_path.c_str(), &source_path_before) != 0 ||
            !regular_single_link(source_path_before)) {
            throw std::runtime_error("source preflight failed");
        }
        ScopedFd source(open(source_path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
        if (!source.valid()) throw std::runtime_error("source open failed");
        struct stat source_before {};
        if (fstat(source.get(), &source_before) != 0 ||
            !same_full_snapshot(source_path_before, source_before) ||
            source_before.st_size < 0 || source_before.st_size > max_bytes_value) {
            throw std::runtime_error("source snapshot changed before read");
        }

        ScopedFd destination(openat(
            directory_fd,
            temporary.c_str(),
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0600
        ));
        if (!destination.valid()) throw std::runtime_error("temporary create failed");
        Sha256 source_digest;
        std::array<uint8_t, kChunkSize> buffer {};
        while (true) {
            require_not_cancelled(operation_id);
            const ssize_t count = read(source.get(), buffer.data(), buffer.size());
            if (count < 0) throw std::runtime_error("source read failed");
            if (count == 0) break;
            total += static_cast<uint64_t>(count);
            if (total > static_cast<uint64_t>(max_bytes_value)) {
                throw std::runtime_error("source exceeds limit");
            }
            source_digest.update(buffer.data(), static_cast<size_t>(count));
            write_all(destination.get(), buffer.data(), static_cast<size_t>(count));
        }
        if (fsync(destination.get()) != 0) throw std::runtime_error("file fsync failed");

        struct stat source_after {};
        struct stat source_path_after {};
        struct stat destination_before_publish {};
        if (fstat(source.get(), &source_after) != 0 ||
            lstat(source_path.c_str(), &source_path_after) != 0 ||
            !same_full_snapshot(source_before, source_after) ||
            !same_full_snapshot(source_after, source_path_after) ||
            total != static_cast<uint64_t>(source_before.st_size) ||
            fstat(destination.get(), &destination_before_publish) != 0 ||
            !regular_single_link(destination_before_publish) ||
            destination_before_publish.st_size != static_cast<off_t>(total)) {
            throw std::runtime_error("copy verification failed");
        }
        uint64_t destination_bytes = 0U;
        const auto destination_digest = hash_fd(
            destination.get(),
            static_cast<uint64_t>(max_bytes_value),
            operation_id,
            &destination_bytes
        );
        const auto copied_digest = source_digest.finish();
        if (destination_bytes != total || destination_digest != copied_digest) {
            throw std::runtime_error("destination digest mismatch");
        }
        final_digest = hex_digest(destination_digest);
        require_not_cancelled(operation_id);
        verify_held_directory(directory_fd, uploads_path, directory_initial);
        write_journal_atomic(journal_fd, operation_id, JournalRecord {
            "PUBLISHING", temporary, final_name, total, final_digest, false, "none"
        });
        struct stat destination_immediate {};
        if (fstat(destination.get(), &destination_immediate) != 0 ||
            !same_full_snapshot(destination_before_publish, destination_immediate)) {
            throw std::runtime_error("temporary changed immediately before publish");
        }
        if (rename_noreplace(directory_fd, temporary.c_str(), final_name.c_str()) != 0) {
            throw std::runtime_error("atomic no-replace publish unavailable");
        }
        published = true;
        if (fsync(directory_fd) != 0) throw std::runtime_error("publish fsync failed");
        write_journal_atomic(journal_fd, operation_id, JournalRecord {
            "PUBLISHED", temporary, final_name, total, final_digest, false, "none"
        });

        struct stat final_stat {};
        if (fstatat(directory_fd, final_name.c_str(), &final_stat, AT_SYMLINK_NOFOLLOW) != 0 ||
            !regular_single_link(final_stat) || final_stat.st_dev != destination_before_publish.st_dev ||
            final_stat.st_ino != destination_before_publish.st_ino ||
            final_stat.st_size != destination_before_publish.st_size) {
            throw std::runtime_error("published file verification failed");
        }
        ScopedFd published_file(openat(
            directory_fd,
            final_name.c_str(),
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        ));
        struct stat published_descriptor {};
        uint64_t published_bytes = 0U;
        if (!published_file.valid() || fstat(published_file.get(), &published_descriptor) != 0 ||
            published_descriptor.st_dev != final_stat.st_dev ||
            published_descriptor.st_ino != final_stat.st_ino ||
            !regular_single_link(published_descriptor)) {
            throw std::runtime_error("published descriptor verification failed");
        }
        const auto published_digest = hash_fd(
            published_file.get(),
            static_cast<uint64_t>(max_bytes_value),
            operation_id,
            &published_bytes
        );
        if (published_bytes != total || published_digest != destination_digest) {
            throw std::runtime_error("published digest mismatch");
        }
        int close_error = 0;
        const bool published_closed = published_file.close_checked(&close_error);
        const bool destination_closed = destination.close_checked(&close_error);
        const bool source_closed = source.close_checked(&close_error);
        if (!published_closed || !destination_closed || !source_closed) {
            errno = close_error;
            throw std::runtime_error("secure import descriptor close failed");
        }
        verify_held_directory(directory_fd, uploads_path, directory_initial);
        require_not_cancelled(operation_id);
        jobjectArray result = string_array(env, {
            std::to_string(total),
            final_digest,
            snapshot_identity(source_after)
        });
        if (result == nullptr) throw std::bad_alloc();
        return result;
    } catch (const std::bad_alloc&) {
        cleanup_failed_import(
            directory.get(), journal_directory.get(), operation_id, temporary, final_name,
            published, total, final_digest, ENOMEM
        );
        throw_java(env, "java/lang/OutOfMemoryError", "secure import allocation failed");
    } catch (const std::exception&) {
        const int failure_error = errno == 0 ? EIO : errno;
        cleanup_failed_import(
            directory.get(), journal_directory.get(), operation_id, temporary, final_name,
            published, total, final_digest, failure_error
        );
        throw_java(env, "java/lang/SecurityException", "secure import failed");
    }
    return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_anka_clawbot_SecureImportNative_readFileBounded(
    JNIEnv* env,
    jobject,
    jstring root_path_value,
    jstring relative_path_value,
    jstring operation_id_value,
    jlong max_bytes_value
) {
    try {
        const std::string root_path = Utf8Chars(env, root_path_value).str();
        const std::string relative_path = Utf8Chars(env, relative_path_value).str();
        const std::string operation_id = Utf8Chars(env, operation_id_value).str();
        if (!is_hex_operation(operation_id) || max_bytes_value < 0 ||
            max_bytes_value > 1024LL * 1024LL) {
            throw std::invalid_argument("invalid bounded read arguments");
        }
        [[maybe_unused]] OperationLease operation(operation_id);
        require_not_cancelled(operation_id);
        struct stat root_initial {};
        ScopedFd root = open_verified_directory(root_path, &root_initial);
        auto source_value = open_relative_regular(root.get(), relative_path);
        if (!source_value.has_value()) return nullptr;
        RelativeFile source = std::move(source_value.value());
        if (source.descriptor_before.st_size < 0 ||
            source.descriptor_before.st_size > max_bytes_value) {
            throw std::runtime_error("bounded read size rejected before allocation");
        }
        std::vector<uint8_t> bytes;
        bytes.reserve(static_cast<size_t>(source.descriptor_before.st_size));
        std::array<uint8_t, kChunkSize> buffer {};
        while (true) {
            require_not_cancelled(operation_id);
            const ssize_t count = read(source.file.get(), buffer.data(), buffer.size());
            if (count < 0) throw std::runtime_error("bounded read failed");
            if (count == 0) break;
            if (bytes.size() + static_cast<size_t>(count) >
                static_cast<size_t>(max_bytes_value)) {
                throw std::runtime_error("bounded read actual size exceeded");
            }
            bytes.insert(bytes.end(), buffer.begin(), buffer.begin() + count);
        }
        struct stat descriptor_after {};
        struct stat path_after {};
        struct stat parent_after {};
        if (fstat(source.file.get(), &descriptor_after) != 0 ||
            fstatat(
                source.parent.get(),
                source.name.c_str(),
                &path_after,
                AT_SYMLINK_NOFOLLOW
            ) != 0 || fstat(source.parent.get(), &parent_after) != 0 ||
            !same_directory_identity(source.parent_before, parent_after) ||
            !same_full_snapshot(source.descriptor_before, descriptor_after) ||
            !same_full_snapshot(descriptor_after, path_after) ||
            bytes.size() != static_cast<size_t>(source.descriptor_before.st_size)) {
            throw std::runtime_error("bounded read changed during operation");
        }
        verify_held_directory(root.get(), root_path, root_initial);
        jbyteArray output = env->NewByteArray(static_cast<jsize>(bytes.size()));
        if (output == nullptr) throw std::bad_alloc();
        if (!bytes.empty()) {
            env->SetByteArrayRegion(
                output,
                0,
                static_cast<jsize>(bytes.size()),
                reinterpret_cast<const jbyte*>(bytes.data())
            );
        }
        return output;
    } catch (const std::bad_alloc&) {
        throw_java(env, "java/lang/OutOfMemoryError", "bounded read allocation failed");
    } catch (const std::exception&) {
        throw_java(env, "java/lang/SecurityException", "bounded read failed");
    }
    return nullptr;
}

extern "C" JNIEXPORT void JNICALL
Java_com_anka_clawbot_SecureImportNative_cancelOperation(
    JNIEnv* env,
    jobject,
    jstring operation_id_value
) {
    try {
        const std::string operation_id = Utf8Chars(env, operation_id_value).str();
        if (!is_hex_operation(operation_id)) throw std::invalid_argument("invalid operation");
        std::lock_guard<std::mutex> lock(g_cancel_mutex);
        g_cancelled.insert(operation_id);
    } catch (const std::exception&) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid operation");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_anka_clawbot_SecureImportNative_finishOperation(
    JNIEnv* env,
    jobject,
    jstring operation_id_value
) {
    try {
        const std::string operation_id = Utf8Chars(env, operation_id_value).str();
        if (!is_hex_operation(operation_id)) throw std::invalid_argument("invalid operation");
        std::lock_guard<std::mutex> lock(g_cancel_mutex);
        if (g_active_operations.find(operation_id) == g_active_operations.end()) {
            g_cancelled.erase(operation_id);
            g_finish_requested.erase(operation_id);
        } else {
            g_finish_requested.insert(operation_id);
        }
    } catch (const std::exception&) {
        throw_java(env, "java/lang/IllegalArgumentException", "invalid operation");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_anka_clawbot_SecureImportNative_acknowledgeImport(
    JNIEnv* env,
    jobject,
    jstring uploads_path_value,
    jstring final_name_value,
    jstring operation_id_value,
    jlong expected_size_value,
    jstring expected_sha256_value
) {
    ScopedFd directory;
    std::optional<OperationLease> operation;
    try {
        const std::string uploads_path = Utf8Chars(env, uploads_path_value).str();
        const std::string final_name = Utf8Chars(env, final_name_value).str();
        const std::string operation_id = Utf8Chars(env, operation_id_value).str();
        const std::string expected_sha256 = Utf8Chars(env, expected_sha256_value).str();
        if (!is_hex_operation(operation_id) || !is_safe_component(final_name, 212U) ||
            expected_size_value < 0 || expected_size_value > 50LL * 1024LL * 1024LL ||
            !valid_digest(expected_sha256)) {
            throw std::invalid_argument("invalid acknowledgement");
        }
        operation.emplace(operation_id);
        struct stat directory_initial {};
        directory = open_verified_directory(uploads_path, &directory_initial);
        ScopedFd journal_directory = open_journal_directory(directory.get());
        const int journal_fd = journal_directory.get();
        std::lock_guard<std::mutex> journal_lock(journal_mutex_for(operation_id));
        recover_pending_replacement_locked(journal_fd, operation_id);
        JournalRecord record;
        const JournalReadStatus status = read_journal_record(
            journal_fd, journal_name(operation_id), &record
        );
        if (status == JournalReadStatus::missing) {
            record = JournalRecord {
                "ACKNOWLEDGED", temp_name(operation_id), final_name,
                static_cast<uint64_t>(expected_size_value), expected_sha256, false, "none"
            };
            if (!verify_receipt_file(directory.get(), record, operation_id)) {
                throw std::runtime_error("idempotent acknowledgement verification failed");
            }
            verify_held_directory(directory.get(), uploads_path, directory_initial);
            return;
        }
        if (status != JournalReadStatus::valid ||
            (record.state != "PUBLISHED" && record.state != "ACKNOWLEDGED") ||
            record.final_name != final_name ||
            record.size != static_cast<uint64_t>(expected_size_value) ||
            record.sha256 != expected_sha256 ||
            !verify_receipt_file(directory.get(), record, operation_id)) {
            throw std::runtime_error("acknowledgement journal mismatch");
        }
        record.state = "ACKNOWLEDGED";
        record.error = "none";
        write_journal_atomic_locked(journal_fd, operation_id, record);
        if (!cleanup_record_locked(
                directory.get(), journal_fd, operation_id, record
            )) {
            throw std::runtime_error("acknowledgement durability failed");
        }
        verify_held_directory(directory.get(), uploads_path, directory_initial);
    } catch (const std::exception&) {
        throw_java(env, "java/lang/SecurityException", "import acknowledgement failed");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_anka_clawbot_SecureImportNative_discardImport(
    JNIEnv* env,
    jobject,
    jstring uploads_path_value,
    jstring final_name_value,
    jstring operation_id_value,
    jlong expected_size_value,
    jstring expected_sha256_value
) {
    ScopedFd directory;
    std::optional<OperationLease> operation;
    try {
        const std::string uploads_path = Utf8Chars(env, uploads_path_value).str();
        const std::string final_name = Utf8Chars(env, final_name_value).str();
        const std::string operation_id = Utf8Chars(env, operation_id_value).str();
        const std::string expected_sha256 = Utf8Chars(env, expected_sha256_value).str();
        if (!is_hex_operation(operation_id) || !is_safe_component(final_name, 212U) ||
            expected_size_value < 0 || expected_size_value > 50LL * 1024LL * 1024LL ||
            !valid_digest(expected_sha256)) {
            throw std::invalid_argument("invalid discard");
        }
        operation.emplace(operation_id);
        struct stat directory_initial {};
        directory = open_verified_directory(uploads_path, &directory_initial);
        ScopedFd journal_directory = open_journal_directory(directory.get());
        const int journal_fd = journal_directory.get();
        std::lock_guard<std::mutex> journal_lock(journal_mutex_for(operation_id));
        recover_pending_replacement_locked(journal_fd, operation_id);
        JournalRecord record;
        const JournalReadStatus status = read_journal_record(
            journal_fd, journal_name(operation_id), &record
        );
        if (status == JournalReadStatus::missing) {
            int absence_error = 0;
            if (entry_absent(directory.get(), final_name, &absence_error)) return;
            throw std::runtime_error("discard journal missing for existing final");
        }
        if (status != JournalReadStatus::valid || record.final_name != final_name ||
            record.size != static_cast<uint64_t>(expected_size_value) ||
            record.sha256 != expected_sha256 ||
            (record.state != "PUBLISHED" && record.state != "PUBLISHING" &&
             record.state != "CLEANUP_REQUIRED")) {
            throw std::runtime_error("discard journal mismatch");
        }
        record.state = "CLEANUP_REQUIRED";
        record.cleanup_final = true;
        record.error = "user_discard";
        write_journal_atomic_locked(journal_fd, operation_id, record);
        if (!cleanup_record_locked(
                directory.get(), journal_fd, operation_id, record
            )) {
            throw std::runtime_error("discard cleanup incomplete");
        }
        verify_held_directory(directory.get(), uploads_path, directory_initial);
    } catch (const std::exception&) {
        throw_java(env, "java/lang/SecurityException", "import discard failed");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_anka_clawbot_SecureImportNative_reconcileImports(
    JNIEnv* env,
    jobject,
    jstring uploads_path_value
) {
    try {
        const std::string uploads_path = Utf8Chars(env, uploads_path_value).str();
        struct stat directory_initial {};
        ScopedFd directory = open_verified_directory(uploads_path, &directory_initial);
        ScopedFd journal_directory = open_journal_directory(directory.get());
        reconcile_directory(directory.get(), journal_directory.get());
        verify_held_directory(directory.get(), uploads_path, directory_initial);
    } catch (const std::exception&) {
        throw_java(env, "java/lang/SecurityException", "import reconciliation failed");
    }
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_anka_clawbot_SecureImportNative_listPendingImports(
    JNIEnv* env,
    jobject,
    jstring uploads_path_value,
    jint max_entries_value
) {
    try {
        const std::string uploads_path = Utf8Chars(env, uploads_path_value).str();
        if (max_entries_value <= 0 ||
            max_entries_value > static_cast<jint>(kReconcileWorkLimit)) {
            throw std::invalid_argument("invalid pending import list limit");
        }
        struct stat directory_initial {};
        ScopedFd directory = open_verified_directory(uploads_path, &directory_initial);
        ScopedFd journal_directory = open_journal_directory(directory.get());
        const auto records = list_pending_records(
            journal_directory.get(), static_cast<size_t>(max_entries_value)
        );
        verify_held_directory(directory.get(), uploads_path, directory_initial);
        jobjectArray result = string_vector_array(env, records);
        if (result == nullptr) throw std::bad_alloc();
        return result;
    } catch (const std::bad_alloc&) {
        throw_java(env, "java/lang/OutOfMemoryError", "pending import list allocation failed");
    } catch (const std::exception&) {
        throw_java(env, "java/lang/SecurityException", "pending import list failed");
    }
    return nullptr;
}
