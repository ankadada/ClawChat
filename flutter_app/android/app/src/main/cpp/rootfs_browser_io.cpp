/*
 * Descriptor-relative file-browser I/O for the rootfs workspace.
 *
 * The guest has the workspace bind-mounted writable, so every component of a
 * browsed path is attacker-reachable. Path-based checks (stat, then open) can be
 * swapped between the check and the use; every operation here walks the tree
 * with openat(O_DIRECTORY | O_NOFOLLOW) relative to its verified parent, checks
 * the opened directory's identity, and then acts on a descriptor:
 *
 *   - list   : fdopendir on the walked directory, fstatat(AT_SYMLINK_NOFOLLOW)
 *              per child (a link is reported as a link, never descended into),
 *   - delete : fstatat on the parent fd, regular single-link check, unlinkat,
 *   - write  : openat(O_CREAT | O_EXCL | O_NOFOLLOW) on the parent fd.
 *
 * The same translation unit is compiled into a host harness
 * (-DROOTFS_BROWSER_HOST_TEST) so the races are executed, not only reviewed.
 */
#ifndef ROOTFS_BROWSER_HOST_TEST
#include <jni.h>
#endif

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <vector>

#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

namespace {

constexpr size_t kMaxComponentBytes = 255U;
constexpr int kTempNameAttempts = 8;

#ifdef ROOTFS_BROWSER_HOST_TEST
/**
 * Host-test hook: make the write loop fail once this many bytes were written
 * (-1 disables it) so cleanup can be asserted without a full disk.
 */
int g_write_failure_after_bytes = -1;
#endif
constexpr size_t kMaxBodyBytes = 1024U * 1024U;
constexpr int kMaxListEntries = 501;  // 500 plus the truncation probe

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
    void reset(int replacement = -1) {
        if (fd_ >= 0) close(fd_);
        fd_ = replacement;
    }

private:
    int fd_;
};

bool is_safe_component(const std::string& value) {
    if (value.empty() || value.size() > kMaxComponentBytes) return false;
    if (value == "." || value == "..") return false;
    if (value.find('/') != std::string::npos) return false;
    if (value.find('\0') != std::string::npos) return false;
    return true;
}

std::vector<std::string> split_components(const std::string& relative) {
    std::vector<std::string> components;
    size_t start = 0;
    while (start <= relative.size()) {
        const size_t slash = relative.find('/', start);
        const std::string piece = relative.substr(
            start,
            slash == std::string::npos ? std::string::npos : slash - start
        );
        if (!piece.empty()) components.push_back(piece);
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return components;
}

bool same_directory(const struct stat& left, const struct stat& right) {
    return S_ISDIR(left.st_mode) && S_ISDIR(right.st_mode) &&
        left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

bool is_regular_single_link(const struct stat& value) {
    return S_ISREG(value.st_mode) && value.st_nlink == 1;
}

/**
 * Opens one directory component below parent_fd without following a symlink and
 * verifies that the descriptor still is the node the name resolved to.
 */
bool open_child_directory(int parent_fd, const std::string& name, ScopedFd* out) {
    struct stat before {};
    if (fstatat(parent_fd, name.c_str(), &before, AT_SYMLINK_NOFOLLOW) != 0) {
        return false;
    }
    if (!S_ISDIR(before.st_mode)) return false;
    ScopedFd child(openat(
        parent_fd,
        name.c_str(),
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    ));
    if (!child.valid()) return false;
    struct stat after {};
    if (fstat(child.get(), &after) != 0 || !same_directory(before, after)) {
        return false;
    }
    *out = std::move(child);
    return true;
}

/** Opens the scope root itself; it must be a real directory, never a link. */
bool open_root(const std::string& root_path, ScopedFd* out) {
    ScopedFd root(open(
        root_path.c_str(),
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    ));
    if (!root.valid()) return false;
    *out = std::move(root);
    return true;
}

/**
 * Walks the first count components under the root descriptor and returns the
 * descriptor of the deepest opened directory.
 */
bool walk_directories(
    int root_fd,
    const std::vector<std::string>& components,
    size_t count,
    ScopedFd* out
) {
    ScopedFd current(dup(root_fd));
    if (!current.valid()) return false;
    for (size_t index = 0; index < count; ++index) {
        ScopedFd next;
        if (!open_child_directory(current.get(), components[index], &next)) {
            return false;
        }
        current = std::move(next);
    }
    *out = std::move(current);
    return true;
}

/**
 * Creates every missing component of a directory path below the verified root,
 * descriptor-relative: each missing level is created with mkdirat and then
 * re-opened with O_DIRECTORY | O_NOFOLLOW and an identity check, so a linked or
 * swapped component fails closed instead of redirecting the creation.
 */
bool create_directories(
    int root_fd,
    const std::vector<std::string>& components
) {
    ScopedFd current(dup(root_fd));
    if (!current.valid()) return false;
    for (const auto& component : components) {
        if (!is_safe_component(component)) return false;
        struct stat existing {};
        if (fstatat(current.get(), component.c_str(), &existing,
                    AT_SYMLINK_NOFOLLOW) == 0) {
            // Anything that is not a real directory (a link, a file, a FIFO)
            // is refused before it can be used.
            if (!S_ISDIR(existing.st_mode)) return false;
            ScopedFd opened(openat(
                current.get(), component.c_str(),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            ));
            if (!opened.valid()) return false;
            struct stat after {};
            if (fstat(opened.get(), &after) != 0 ||
                !same_directory(existing, after)) {
                return false;
            }
            current = std::move(opened);
            continue;
        }
        if (errno != ENOENT) return false;
        if (mkdirat(current.get(), component.c_str(), 0700) != 0 &&
            errno != EEXIST) {
            return false;
        }
        struct stat created {};
        if (fstatat(current.get(), component.c_str(), &created,
                    AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISDIR(created.st_mode)) {
            return false;
        }
        ScopedFd opened(openat(
            current.get(), component.c_str(),
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ));
        if (!opened.valid()) return false;
        struct stat after {};
        if (fstat(opened.get(), &after) != 0 ||
            !same_directory(created, after)) {
            return false;
        }
        current = std::move(opened);
    }
    return true;
}

/** Creates a directory path (all missing levels) below the scope root. */
bool create_directory_path(int root_fd, const std::string& relative) {
    const std::vector<std::string> components = split_components(relative);
    if (components.empty()) return false;
    return create_directories(root_fd, components);
}

struct Entry {
    std::string name;
    bool is_directory = false;
    bool is_link = false;
    long long size = 0;
    long long modified_epoch_ms = 0;
};

/**
 * Lists one directory descriptor-relative. A link child is reported as a link
 * and never as a directory, so the caller cannot descend into it.
 */
bool list_directory_entries(
    int root_fd,
    const std::vector<std::string>& components,
    int max_entries,
    std::vector<Entry>* out,
    bool* truncated
) {
    *truncated = false;
    ScopedFd directory;
    if (!walk_directories(root_fd, components, components.size(), &directory)) {
        return false;
    }
    const int duplicate = dup(directory.get());
    if (duplicate < 0) return false;
    DIR* stream = fdopendir(duplicate);
    if (stream == nullptr) {
        close(duplicate);
        return false;
    }
    const int limit = max_entries <= 0
        ? kMaxListEntries
        : (max_entries > kMaxListEntries ? kMaxListEntries : max_entries);
    std::vector<Entry> collected;
    bool overflow = false;
    while (true) {
        errno = 0;
        dirent* raw = readdir(stream);
        if (raw == nullptr) break;
        const std::string name(raw->d_name);
        if (name == "." || name == "..") continue;
        struct stat value {};
        if (fstatat(directory.get(), name.c_str(), &value, AT_SYMLINK_NOFOLLOW) != 0) {
            continue;
        }
        if (collected.size() >= static_cast<size_t>(limit)) {
            overflow = true;
            continue;
        }
        Entry entry;
        entry.name = name;
        entry.is_link = S_ISLNK(value.st_mode);
        entry.is_directory = !entry.is_link && S_ISDIR(value.st_mode);
        entry.size = entry.is_directory ? 0 : static_cast<long long>(value.st_size);
        entry.modified_epoch_ms = static_cast<long long>(value.st_mtime) * 1000LL;
        collected.push_back(std::move(entry));
    }
    closedir(stream);
    std::sort(
        collected.begin(),
        collected.end(),
        [](const Entry& left, const Entry& right) {
            if (left.is_directory != right.is_directory) return left.is_directory;
            return left.name < right.name;
        }
    );
    *out = std::move(collected);
    *truncated = overflow;
    return true;
}

/**
 * Splits a relative path into parent components and the leaf name, refusing
 * traversal or unusable names.
 */
bool split_leaf(
    const std::string& relative,
    std::vector<std::string>* parents,
    std::string* leaf
) {
    const std::vector<std::string> components = split_components(relative);
    if (components.empty()) return false;
    for (const auto& component : components) {
        if (component == ".." || component.find('\0') != std::string::npos) {
            return false;
        }
    }
    *leaf = components.back();
    if (!is_safe_component(*leaf)) return false;
    parents->assign(components.begin(), components.end() - 1);
    return true;
}

/** Deletes only a plain file, through the parent descriptor. */
bool delete_regular_file(int root_fd, const std::string& relative, bool* missing) {
    *missing = false;
    std::vector<std::string> parents;
    std::string leaf;
    if (!split_leaf(relative, &parents, &leaf)) return false;
    ScopedFd parent;
    if (!walk_directories(root_fd, parents, parents.size(), &parent)) {
        *missing = true;
        return false;
    }
    struct stat value {};
    if (fstatat(parent.get(), leaf.c_str(), &value, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) {
            *missing = true;
            return false;
        }
        return false;
    }
    // A link is its own node: unlinking it never touches the target, and the
    // browser treats links as non-deletable so nothing surprising happens.
    if (S_ISLNK(value.st_mode)) return false;
    if (!is_regular_single_link(value)) return false;
    if (unlinkat(parent.get(), leaf.c_str(), 0) != 0) return false;
    return true;
}

/** Writes one new file through the parent descriptor. */
bool unlink_if_same(int parent_fd, const std::string& name, const struct stat& expected) {
    struct stat current {};
    if (fstatat(parent_fd, name.c_str(), &current, AT_SYMLINK_NOFOLLOW) != 0) {
        return errno == ENOENT;
    }
    if (current.st_dev != expected.st_dev || current.st_ino != expected.st_ino) {
        // The name no longer refers to the node we created: never unlink it.
        return false;
    }
    return unlinkat(parent_fd, name.c_str(), 0) == 0 || errno == ENOENT;
}

bool same_file(const struct stat& left, const struct stat& right) {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

bool write_all_to(int fd, const std::string& body) {
    size_t offset = 0;
    while (offset < body.size()) {
        const ssize_t step = write(fd, body.data() + offset, body.size() - offset);
        if (step < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (step == 0) return false;
        offset += static_cast<size_t>(step);
#ifdef ROOTFS_BROWSER_HOST_TEST
        // Test hook: fail once this many bytes were written, so cleanup can be
        // asserted without filling a disk.
        if (g_write_failure_after_bytes >= 0 &&
            offset >= static_cast<size_t>(g_write_failure_after_bytes)
        ) {
            return false;
        }
#endif
    }
    return true;
}

/** A unique, non-predictable-enough temp name inside the guest-writable parent. */
std::string temp_candidate_name(int attempt) {
    static std::atomic<unsigned long long> counter{0};
    const unsigned long long value = counter.fetch_add(1ULL);
    return ".clawchat-write-" + std::to_string(static_cast<long long>(getpid())) +
        "-" + std::to_string(value) + "-" + std::to_string(attempt) + ".tmp";
}

/**
 * Writes one file through the verified parent descriptor.
 *
 * create_new: a strict no-replace create (O_CREAT | O_EXCL), and the file is
 * removed again if the write or fsync fails.
 *
 * overwrite: the existing inode is NEVER opened and never truncated. The new
 * content is written to a fresh O_EXCL temp file in the same directory, fsynced,
 * and only then the directory entry is replaced with renameat. A concurrent
 * link() to the old inode therefore cannot make this call clear data that
 * another name still points at; a symlink, FIFO or hard-linked target is refused
 * before anything is created.
 *
 * Any failure after the temp file exists unlinks exactly that node (identity
 * checked through the same parent fd) so no partial file is left behind.
 */
bool write_regular_file(
    int root_fd,
    const std::string& relative,
    const std::string& body,
    bool create_new,
    bool* exists
) {
    *exists = false;
    if (body.size() > kMaxBodyBytes) return false;
    std::vector<std::string> parents;
    std::string leaf;
    if (!split_leaf(relative, &parents, &leaf)) return false;
    ScopedFd parent;
    if (!walk_directories(root_fd, parents, parents.size(), &parent)) return false;

    if (create_new) {
        ScopedFd created(openat(
            parent.get(),
            leaf.c_str(),
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0700
        ));
        if (!created.valid()) {
            if (errno == EEXIST) *exists = true;
            return false;
        }
        struct stat created_stat {};
        if (fstat(created.get(), &created_stat) != 0) {
            return false;
        }
        if (!is_regular_single_link(created_stat)) {
            // A guest with write access to this directory may have linked or
            // replaced the fresh node already; drop exactly that node.
            unlink_if_same(parent.get(), leaf, created_stat);
            return false;
        }
        if (!write_all_to(created.get(), body) || fsync(created.get()) != 0) {
            // Remove exactly the node this call created.
            unlink_if_same(parent.get(), leaf, created_stat);
            return false;
        }
        return true;
    }

    // Refuse anything that is not a plain single-link file before touching the
    // directory. No open of the existing node: a FIFO cannot block us and a
    // link cannot be followed.
    struct stat existing {};
    if (fstatat(parent.get(), leaf.c_str(), &existing, AT_SYMLINK_NOFOLLOW) == 0) {
        if (S_ISLNK(existing.st_mode) || !S_ISREG(existing.st_mode)) return false;
        if (existing.st_nlink != 1) return false;
    }

    ScopedFd temp;
    std::string temp_name;
    struct stat temp_stat {};
    for (int attempt = 0; attempt < kTempNameAttempts && !temp.valid(); ++attempt) {
        const std::string candidate = temp_candidate_name(attempt);
        ScopedFd file(openat(
            parent.get(),
            candidate.c_str(),
            // O_NONBLOCK so opening a special node could never park the thread;
            // O_EXCL + O_NOFOLLOW so a planted node is refused instead of used.
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            0700
        ));
        if (file.valid()) {
            temp = std::move(file);
            temp_name = candidate;
            break;
        }
        if (errno != EEXIST) return false;
    }
    if (!temp.valid()) return false;
    if (fstat(temp.get(), &temp_stat) != 0 || !is_regular_single_link(temp_stat)) {
        unlink_if_same(parent.get(), temp_name, temp_stat);
        return false;
    }
    if (!write_all_to(temp.get(), body) || fsync(temp.get()) != 0) {
        unlink_if_same(parent.get(), temp_name, temp_stat);
        return false;
    }
    // The temp entry must still be our inode: the guest owns this directory and
    // could have moved its own file into the name we picked.
    struct stat before_rename {};
    if (fstatat(parent.get(), temp_name.c_str(), &before_rename, AT_SYMLINK_NOFOLLOW) != 0 ||
        !same_file(before_rename, temp_stat)
    ) {
        return false;
    }
    if (renameat(parent.get(), temp_name.c_str(), parent.get(), leaf.c_str()) != 0) {
        unlink_if_same(parent.get(), temp_name, temp_stat);
        return false;
    }
    // Post-condition: the entry names our fresh inode and nothing else does.
    struct stat replaced {};
    if (fstatat(parent.get(), leaf.c_str(), &replaced, AT_SYMLINK_NOFOLLOW) != 0 ||
        !same_file(replaced, temp_stat) ||
        !is_regular_single_link(replaced)
    ) {
        return false;
    }
    return true;
}

}  // namespace

#ifndef ROOTFS_BROWSER_HOST_TEST

namespace {

std::string jstring_to_string(JNIEnv* env, jstring value) {
    if (value == nullptr) return std::string();
    const char* utf8 = env->GetStringUTFChars(value, nullptr);
    if (utf8 == nullptr) return std::string();
    std::string result(utf8);
    env->ReleaseStringUTFChars(value, utf8);
    return result;
}

}  // namespace

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_anka_clawbot_SecureImportNative_listRootfsDirectoryBounded(
    JNIEnv* env,
    jclass,
    jstring root_path,
    jstring relative_path,
    jint max_entries
) {
    ScopedFd root;
    if (!open_root(jstring_to_string(env, root_path), &root)) return nullptr;
    const std::vector<std::string> components =
        split_components(jstring_to_string(env, relative_path));
    for (const auto& component : components) {
        if (component == ".." || component.find('\0') != std::string::npos) {
            return nullptr;
        }
        if (!is_safe_component(component)) return nullptr;
    }
    std::vector<Entry> entries;
    bool truncated = false;
    if (!list_directory_entries(
            root.get(),
            components,
            max_entries,
            &entries,
            &truncated
        )
    ) {
        return nullptr;
    }
    jclass string_class = env->FindClass("java/lang/String");
    if (string_class == nullptr) return nullptr;
    jobjectArray rows = env->NewObjectArray(
        static_cast<jsize>(entries.size()),
        string_class,
        nullptr
    );
    if (rows == nullptr) return nullptr;
    for (size_t index = 0; index < entries.size(); ++index) {
        const Entry& entry = entries[index];
        const std::string encoded =
            entry.name + "\t" +
            (entry.is_link ? "l" : (entry.is_directory ? "d" : "f")) + "\t" +
            std::to_string(entry.size) + "\t" +
            std::to_string(entry.modified_epoch_ms);
        env->SetObjectArrayElement(
            rows,
            static_cast<jsize>(index),
            env->NewStringUTF(encoded.c_str())
        );
    }
    return rows;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_anka_clawbot_SecureImportNative_deleteRootfsFileBounded(
    JNIEnv* env,
    jclass,
    jstring root_path,
    jstring relative_path
) {
    ScopedFd root;
    if (!open_root(jstring_to_string(env, root_path), &root)) return JNI_FALSE;
    bool missing = false;
    const bool deleted = delete_regular_file(
        root.get(),
        jstring_to_string(env, relative_path),
        &missing
    );
    // A file that is already gone is not an error.
    return (deleted || missing) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_anka_clawbot_SecureImportNative_writeRootfsFileBounded(
    JNIEnv* env,
    jclass,
    jstring root_path,
    jstring relative_path,
    jstring body,
    jboolean create_new
) {
    ScopedFd root;
    if (!open_root(jstring_to_string(env, root_path), &root)) return JNI_FALSE;
    bool exists = false;
    const bool written = write_regular_file(
        root.get(),
        jstring_to_string(env, relative_path),
        jstring_to_string(env, body),
        create_new == JNI_TRUE,
        &exists
    );
    return written ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_anka_clawbot_SecureImportNative_createRootfsDirectoryBounded(
    JNIEnv* env,
    jclass,
    jstring root_path,
    jstring relative_path
) {
    ScopedFd root;
    if (!open_root(jstring_to_string(env, root_path), &root)) return JNI_FALSE;
    return create_directory_path(
        root.get(),
        jstring_to_string(env, relative_path)
    ) ? JNI_TRUE : JNI_FALSE;
}

#endif  // ROOTFS_BROWSER_HOST_TEST
