/*
 * Descriptor-relative MCP launch-script I/O.
 *
 * The MCP launch tree (app files dir / home / .mcp / run / server / start)
 * lives under the app home directory, which is bind-mounted writable into the
 * guest rootfs. A hostile or broken guest can therefore plant or swap symlinks
 * at any level while the app is creating, reaping, or sweeping those
 * directories. Every operation here is fd-relative (openat / mkdirat / unlinkat
 * / fstatat) with O_NOFOLLOW plus an identity check on the opened directory, so
 * no decision is ever re-resolved by pathname: a swapped component is refused
 * instead of followed, and cleanup only ever unlinks.
 *
 * The same translation unit is compiled into a host test harness (with
 * -DMCP_LAUNCH_HOST_TEST), so the race behaviour is executed, not only reviewed.
 */
#ifndef MCP_LAUNCH_HOST_TEST
#include <jni.h>
#endif

#include <cerrno>
#include <chrono>
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

constexpr const char* kMcpRootName = ".mcp";
constexpr const char* kScriptName = "launch.sh";
constexpr size_t kMaxSegmentBytes = 120U;
constexpr size_t kMaxBodyBytes = 256U * 1024U;

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

bool is_safe_segment(const std::string& value) {
    if (value.empty() || value.size() > kMaxSegmentBytes) return false;
    if (value == "." || value == "..") return false;
    for (const char character : value) {
        const bool allowed =
            (character >= 'A' && character <= 'Z') ||
            (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9') ||
            character == '.' || character == '_' || character == '-';
        if (!allowed) return false;
    }
    return true;
}

bool is_safe_absolute_path(const std::string& value) {
    if (value.empty() || value.size() > PATH_MAX) return false;
    if (value.front() != '/') return false;
    // Components may only be traversed forward: no ".." rewind.
    size_t start = 1;
    while (start <= value.size()) {
        const size_t slash = value.find('/', start);
        const std::string component = value.substr(
            start,
            slash == std::string::npos ? std::string::npos : slash - start
        );
        if (component == "..") return false;
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return true;
}

std::string directory_identity(const struct stat& value) {
    return std::to_string(static_cast<unsigned long long>(value.st_dev)) + ":" +
        std::to_string(static_cast<unsigned long long>(value.st_ino));
}

bool same_directory(const struct stat& left, const struct stat& right) {
    return S_ISDIR(left.st_mode) && S_ISDIR(right.st_mode) &&
        left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

#ifdef MCP_LAUNCH_HOST_TEST
// Host-harness seam: runs immediately before the final AT_REMOVEDIR so a test
// can replace the target between the identity-checked open and the rmdir. It is
// compiled out of the device build.
typedef void (*BeforeFinalRmdirHook)(int parent_fd, const char* name);
BeforeFinalRmdirHook g_before_final_rmdir_hook = nullptr;

void set_before_final_rmdir_hook(BeforeFinalRmdirHook hook) {
    g_before_final_rmdir_hook = hook;
}
#endif

// Removes parent_fd/name as a directory only while the name still resolves to
// the node the caller opened and cleared. The final rmdir is therefore guarded
// by a fresh fstatat(AT_SYMLINK_NOFOLLOW) plus a device:inode comparison with
// the opened descriptor:
//   * same directory     -> AT_REMOVEDIR;
//   * a different directory -> refused, because that replacement (even an empty
//     one) is not ours to delete;
//   * a symlink or other non-directory -> only that node is unlinked, never
//     followed and never treated as the cleared directory;
//   * already gone       -> success (ENOENT).
// Returns true when the name is gone afterwards.
bool remove_directory_name(
    int parent_fd,
    const std::string& name,
    const struct stat& expected
) {
#ifdef MCP_LAUNCH_HOST_TEST
    if (g_before_final_rmdir_hook != nullptr) {
        g_before_final_rmdir_hook(parent_fd, name.c_str());
    }
#endif
    struct stat current {};
    if (fstatat(parent_fd, name.c_str(), &current, AT_SYMLINK_NOFOLLOW) != 0) {
        return errno == ENOENT;
    }
    if (same_directory(expected, current)) {
        if (unlinkat(parent_fd, name.c_str(), AT_REMOVEDIR) == 0) return true;
        return errno == ENOENT;
    }
    if (S_ISDIR(current.st_mode)) {
        // A different directory now owns the name. Deleting it would destroy a
        // replacement this cleanup does not own.
        return false;
    }
    if (unlinkat(parent_fd, name.c_str(), 0) == 0) return true;
    return errno == ENOENT;
}

// Opens a directory relative to parent_fd without following a symlink and
// verifies the descriptor still is the node the name resolves to. Sets
// missing/unsafe instead of guessing.
bool open_child_directory(
    int parent_fd,
    const std::string& name,
    ScopedFd* out,
    bool* missing,
    bool* unsafe
) {
    *missing = false;
    *unsafe = false;
    struct stat path_before {};
    if (fstatat(parent_fd, name.c_str(), &path_before, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) {
            *missing = true;
            return false;
        }
        *unsafe = true;
        return false;
    }
    if (!S_ISDIR(path_before.st_mode)) {
        // A symlink or a file planted at this level is never used.
        *unsafe = true;
        return false;
    }
    ScopedFd directory(openat(
        parent_fd,
        name.c_str(),
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    ));
    if (!directory.valid()) {
        *unsafe = true;
        return false;
    }
    struct stat descriptor_after {};
    if (fstat(directory.get(), &descriptor_after) != 0 ||
        !same_directory(path_before, descriptor_after)
    ) {
        *unsafe = true;
        return false;
    }
    *out = std::move(directory);
    return true;
}

bool create_child_directory(int parent_fd, const std::string& name, bool* existed) {
    *existed = false;
    if (mkdirat(parent_fd, name.c_str(), 0700) == 0) return true;
    if (errno == EEXIST) {
        *existed = true;
        return true;
    }
    return false;
}

// Opens (creating when allowed) one component of the launch chain.
bool open_or_create_child(
    int parent_fd,
    const std::string& name,
    bool create,
    ScopedFd* out,
    bool* missing,
    std::string* error
) {
    bool unsafe = false;
    if (open_child_directory(parent_fd, name, out, missing, &unsafe)) return true;
    if (unsafe) {
        *error = "launch path component is not a plain directory";
        return false;
    }
    if (!create) return false;  // missing, reported through *missing
    bool existed = false;
    if (!create_child_directory(parent_fd, name, &existed)) {
        *error = "launch directory could not be created";
        return false;
    }
    if (existed) {
        // A racing node appeared between the failed open and mkdirat: only a
        // plain directory is adopted, never a link that won the race.
        bool raced_unsafe = false;
        bool raced_missing = false;
        if (!open_child_directory(parent_fd, name, out, &raced_missing, &raced_unsafe) ||
            raced_unsafe
        ) {
            *error = "launch path component was replaced";
            return false;
        }
        return true;
    }
    bool created_unsafe = false;
    if (!open_child_directory(parent_fd, name, out, missing, &created_unsafe) ||
        created_unsafe
    ) {
        *error = "launch directory could not be opened";
        return false;
    }
    return true;
}

bool write_all(int fd, const std::string& body) {
    size_t written = 0;
    while (written < body.size()) {
        const ssize_t step = write(fd, body.data() + written, body.size() - written);
        if (step < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (step == 0) return false;
        written += static_cast<size_t>(step);
    }
    return true;
}

// Removes everything inside directory_fd without following symlinks and without
// ever re-resolving a pathname. A symlinked child is unlinked, never entered.
bool remove_directory_contents(int directory_fd) {
    const int duplicate = dup(directory_fd);
    if (duplicate < 0) return false;
    DIR* stream = fdopendir(duplicate);
    if (stream == nullptr) {
        close(duplicate);
        return false;
    }
    bool ok = true;
    while (true) {
        errno = 0;
        dirent* entry = readdir(stream);
        if (entry == nullptr) break;
        const std::string name(entry->d_name);
        if (name == "." || name == "..") continue;
        struct stat value {};
        if (fstatat(directory_fd, name.c_str(), &value, AT_SYMLINK_NOFOLLOW) != 0) {
            ok = false;
            continue;
        }
        if (S_ISDIR(value.st_mode)) {
            ScopedFd child(openat(
                directory_fd,
                name.c_str(),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            ));
            struct stat descriptor {};
            if (!child.valid() || fstat(child.get(), &descriptor) != 0 ||
                !same_directory(value, descriptor)
            ) {
                // A swapped or symlinked directory: unlink the node itself.
                if (unlinkat(directory_fd, name.c_str(), 0) != 0 && errno != ENOENT) {
                    ok = false;
                }
                continue;
            }
            if (!remove_directory_contents(child.get())) ok = false;
            // Re-check the name before the final rmdir: a swapped-in
            // replacement directory must never be deleted.
            if (!remove_directory_name(directory_fd, name, descriptor)) {
                ok = false;
            }
            continue;
        }
        if (unlinkat(directory_fd, name.c_str(), 0) != 0 && errno != ENOENT) ok = false;
    }
    closedir(stream);
    return ok;
}

// Opens the app home directory, creating it only when asked. The home itself
// must be a plain directory: a link there is never followed.
bool open_home_directory(
    const std::string& home,
    bool create,
    ScopedFd* out,
    std::string* error
) {
    bool missing = false;
    bool unsafe = false;
    if (open_child_directory(AT_FDCWD, home, out, &missing, &unsafe) && !unsafe) {
        return true;
    }
    if (unsafe) {
        *error = "launch root is not a plain directory";
        return false;
    }
    if (!missing || !create) {
        *error = "launch root is missing";
        return false;
    }
    if (mkdir(home.c_str(), 0700) != 0 && errno != EEXIST) {
        *error = "launch root could not be created";
        return false;
    }
    bool created_unsafe = false;
    if (!open_child_directory(AT_FDCWD, home, out, &missing, &created_unsafe) ||
        created_unsafe
    ) {
        *error = "launch root is not a plain directory";
        return false;
    }
    return true;
}

struct LaunchChain {
    ScopedFd mcp;
    ScopedFd run;
    ScopedFd server;
    ScopedFd start;
    struct stat start_stat {};
    bool start_opened = false;
};

// Walks home/.mcp/run/server/start fd-relative. Missing components are created
// when create is true; otherwise a missing component is reported through
// chain_missing. Any symlinked component fails closed.
bool walk_launch_chain(
    const std::string& home,
    const std::string& run,
    const std::string& server,
    const std::string& start_name,
    bool create,
    ScopedFd* out_home,
    LaunchChain* chain,
    bool* chain_missing,
    std::string* error
) {
    *chain_missing = false;
    if (!is_safe_absolute_path(home) || !is_safe_segment(run) ||
        !is_safe_segment(server) || !is_safe_segment(start_name)
    ) {
        *error = "invalid launch path";
        return false;
    }
    ScopedFd home_fd;
    if (!open_home_directory(home, create, &home_fd, error)) return false;
    bool missing = false;
    if (!open_or_create_child(
            home_fd.get(),
            kMcpRootName,
            create,
            &chain->mcp,
            &missing,
            error
        )
    ) {
        if (missing) {
            *chain_missing = true;
            return true;
        }
        return false;
    }
    if (!open_or_create_child(chain->mcp.get(), run, create, &chain->run, &missing, error)) {
        if (missing) {
            *chain_missing = true;
            return true;
        }
        return false;
    }
    if (!open_or_create_child(
            chain->run.get(),
            server,
            create,
            &chain->server,
            &missing,
            error
        )
    ) {
        if (missing) {
            *chain_missing = true;
            return true;
        }
        return false;
    }
    bool unsafe = false;
    if (!open_child_directory(
            chain->server.get(),
            start_name,
            &chain->start,
            &missing,
            &unsafe
        )
    ) {
        if (unsafe) {
            // A symlink or file where the start directory belongs.
            *error = "launch directory is not a plain directory";
            return false;
        }
        if (!create) {
            *chain_missing = true;
            return true;
        }
        // A start directory is always a fresh node: an existing one (even a
        // plain directory) is never adopted for a new start.
        if (mkdirat(chain->server.get(), start_name.c_str(), 0700) != 0) {
            *error = "launch directory could not be created";
            return false;
        }
        bool created_unsafe = false;
        if (!open_child_directory(
                chain->server.get(),
                start_name,
                &chain->start,
                &missing,
                &created_unsafe
            ) ||
            created_unsafe
        ) {
            *error = "launch directory could not be opened";
            return false;
        }
    } else if (create) {
        // The name already existed: refuse instead of writing into a directory
        // this start did not create.
        *error = "launch directory already exists";
        return false;
    }
    if (fstat(chain->start.get(), &chain->start_stat) != 0) {
        *error = "launch directory is unavailable";
        return false;
    }
    chain->start_opened = true;
    *out_home = std::move(home_fd);
    return true;
}

struct CreateResult {
    bool ok = false;
    std::string host_path;
    std::string identity;
    std::string error;
};

// Creates one start directory and writes the launch script into it. Used by the
// JNI wrapper and by the host harness.
CreateResult create_launch_script(
    const std::string& home,
    const std::string& run,
    const std::string& server,
    const std::string& start_name,
    const std::string& body
) {
    CreateResult result;
    if (body.size() > kMaxBodyBytes) {
        result.error = "launch script body is too large";
        return result;
    }
    ScopedFd home_fd;
    LaunchChain chain;
    bool chain_missing = false;
    if (!walk_launch_chain(
            home,
            run,
            server,
            start_name,
            true,
            &home_fd,
            &chain,
            &chain_missing,
            &result.error
        )
    ) {
        return result;
    }
    if (!chain.start_opened) {
        result.error = "launch directory is unavailable";
        return result;
    }
    ScopedFd script(openat(
        chain.start.get(),
        kScriptName,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0700
    ));
    if (!script.valid()) {
        result.error = "launch script could not be created";
        return result;
    }
    struct stat script_stat {};
    if (fstat(script.get(), &script_stat) != 0 || !S_ISREG(script_stat.st_mode) ||
        script_stat.st_nlink != 1
    ) {
        result.error = "launch script is not a plain file";
        return result;
    }
    if (fchmod(script.get(), 0700) != 0 || !write_all(script.get(), body)) {
        result.error = "launch script could not be written";
        return result;
    }
    struct stat path_after {};
    if (fstatat(
            chain.server.get(),
            start_name.c_str(),
            &path_after,
            AT_SYMLINK_NOFOLLOW
        ) != 0 ||
        !same_directory(chain.start_stat, path_after)
    ) {
        // The start directory was swapped while the script was written.
        result.error = "launch directory was replaced";
        return result;
    }
    result.ok = true;
    result.host_path =
        home + "/" + kMcpRootName + "/" + run + "/" + server + "/" + start_name + "/" +
        kScriptName;
    result.identity = directory_identity(chain.start_stat);
    return result;
}

// Deletes one start directory (and now-empty parents) without following any
// symlink and only when the directory still is the one that was created.
// Returns true when the directory is gone, false when the delete was refused.
bool delete_launch_directory(
    const std::string& home,
    const std::string& run,
    const std::string& server,
    const std::string& start_name,
    const std::string& expected_identity
) {
    ScopedFd home_fd;
    LaunchChain chain;
    bool chain_missing = false;
    std::string error;
    if (!walk_launch_chain(
            home,
            run,
            server,
            start_name,
            false,
            &home_fd,
            &chain,
            &chain_missing,
            &error
        )
    ) {
        // Unsafe or invalid: never fall back to a pathname delete.
        return false;
    }
    if (chain_missing || !chain.start_opened) return true;  // already gone
    if (!expected_identity.empty() &&
        directory_identity(chain.start_stat) != expected_identity
    ) {
        // A substituted node is left alone instead of being deleted.
        return false;
    }
    if (!remove_directory_contents(chain.start.get())) return false;
    // Only the directory that was opened and cleared may be removed. A replaced
    // directory is refused; a replaced symlink/file is unlinked without AT_REMOVEDIR.
    if (!remove_directory_name(chain.server.get(), start_name, chain.start_stat)) {
        return false;
    }
    struct stat server_identity {};
    if (fstat(chain.server.get(), &server_identity) == 0) {
        // Empty parents only, and only while the name still is that directory.
        remove_directory_name(chain.run.get(), server, server_identity);
    }
    struct stat run_identity {};
    if (fstat(chain.run.get(), &run_identity) == 0) {
        remove_directory_name(chain.mcp.get(), run, run_identity);
    }
    return true;
}

// Removes start directories that no live child owns. Symlinked or substituted
// nodes are unlinked, never entered; live directories (by device:inode) and
// directories inside the grace window are left alone.
int sweep_launch_directories(
    const std::string& home,
    long long max_age_ms,
    const std::vector<std::string>& live_identities
) {
    if (!is_safe_absolute_path(home)) return -1;
    ScopedFd home_fd;
    std::string error;
    if (!open_home_directory(home, false, &home_fd, &error)) return 0;
    bool missing = false;
    bool unsafe = false;
    ScopedFd mcp;
    if (!open_child_directory(home_fd.get(), kMcpRootName, &mcp, &missing, &unsafe) ||
        unsafe
    ) {
        // Nothing to sweep, or a symlinked root we refuse to follow.
        return 0;
    }

    const long long now_ms = static_cast<long long>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()
        ).count()
    );
    const long long cutoff = now_ms - max_age_ms;
    int removed = 0;

    const int run_duplicate = dup(mcp.get());
    if (run_duplicate < 0) return 0;
    DIR* run_stream = fdopendir(run_duplicate);
    if (run_stream == nullptr) {
        close(run_duplicate);
        return 0;
    }
    while (true) {
        errno = 0;
        dirent* run_entry = readdir(run_stream);
        if (run_entry == nullptr) break;
        const std::string run_name(run_entry->d_name);
        if (run_name == "." || run_name == "..") continue;
        struct stat run_stat {};
        if (fstatat(mcp.get(), run_name.c_str(), &run_stat, AT_SYMLINK_NOFOLLOW) != 0) {
            continue;
        }
        if (!S_ISDIR(run_stat.st_mode) || !is_safe_segment(run_name)) {
            // A symlinked or unexpected run level: unlink only.
            if (unlinkat(mcp.get(), run_name.c_str(), 0) == 0) removed++;
            continue;
        }
        ScopedFd run;
        bool run_missing = false;
        bool run_unsafe = false;
        if (!open_child_directory(mcp.get(), run_name, &run, &run_missing, &run_unsafe) ||
            run_unsafe
        ) {
            continue;
        }
        const int server_duplicate = dup(run.get());
        if (server_duplicate < 0) continue;
        DIR* server_stream = fdopendir(server_duplicate);
        if (server_stream == nullptr) {
            close(server_duplicate);
            continue;
        }
        while (true) {
            errno = 0;
            dirent* server_entry = readdir(server_stream);
            if (server_entry == nullptr) break;
            const std::string server_name(server_entry->d_name);
            if (server_name == "." || server_name == "..") continue;
            struct stat server_stat {};
            if (fstatat(run.get(), server_name.c_str(), &server_stat, AT_SYMLINK_NOFOLLOW) !=
                0
            ) {
                continue;
            }
            if (!S_ISDIR(server_stat.st_mode) || !is_safe_segment(server_name)) {
                if (unlinkat(run.get(), server_name.c_str(), 0) == 0) removed++;
                continue;
            }
            ScopedFd server;
            bool server_missing = false;
            bool server_unsafe = false;
            if (!open_child_directory(
                    run.get(),
                    server_name,
                    &server,
                    &server_missing,
                    &server_unsafe
                ) ||
                server_unsafe
            ) {
                continue;
            }
            const int start_duplicate = dup(server.get());
            if (start_duplicate < 0) continue;
            DIR* start_stream = fdopendir(start_duplicate);
            if (start_stream == nullptr) {
                close(start_duplicate);
                continue;
            }
            while (true) {
                errno = 0;
                dirent* start_entry = readdir(start_stream);
                if (start_entry == nullptr) break;
                const std::string start_name(start_entry->d_name);
                if (start_name == "." || start_name == "..") continue;
                struct stat start_stat {};
                if (fstatat(
                        server.get(),
                        start_name.c_str(),
                        &start_stat,
                        AT_SYMLINK_NOFOLLOW
                    ) != 0
                ) {
                    continue;
                }
                if (!S_ISDIR(start_stat.st_mode)) {
                    // The reaper only ever unlinks a symlinked start node.
                    if (unlinkat(server.get(), start_name.c_str(), 0) == 0) removed++;
                    continue;
                }
                const std::string identity = directory_identity(start_stat);
                bool is_live = false;
                for (const auto& live_identity : live_identities) {
                    if (live_identity == identity) {
                        is_live = true;
                        break;
                    }
                }
                if (is_live) continue;
                const long long modified_ms =
                    static_cast<long long>(start_stat.st_mtime) * 1000LL;
                if (modified_ms > cutoff) continue;
                ScopedFd start;
                bool start_missing = false;
                bool start_unsafe = false;
                if (!open_child_directory(
                        server.get(),
                        start_name,
                        &start,
                        &start_missing,
                        &start_unsafe
                    ) ||
                    start_unsafe
                ) {
                    continue;
                }
                struct stat descriptor {};
                if (fstat(start.get(), &descriptor) != 0 ||
                    !same_directory(start_stat, descriptor)
                ) {
                    continue;
                }
                if (!remove_directory_contents(start.get())) continue;
                if (remove_directory_name(server.get(), start_name, descriptor)) removed++;
            }
            closedir(start_stream);
            // Empty parents only, and only while the name still resolves to the
            // directory that was opened above.
            struct stat server_identity {};
            if (fstat(server.get(), &server_identity) == 0) {
                remove_directory_name(run.get(), server_name, server_identity);
            }
        }
        closedir(server_stream);
        struct stat run_identity {};
        if (fstat(run.get(), &run_identity) == 0) {
            remove_directory_name(mcp.get(), run_name, run_identity);
        }
    }
    closedir(run_stream);
    return removed;
}

}  // namespace

#ifdef MCP_LAUNCH_HOST_TEST

// Nothing: the harness includes this file and calls the helpers directly.

#else

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
Java_com_anka_clawbot_SecureImportNative_createMcpLaunchScript(
    JNIEnv* env,
    jclass,
    jstring home_dir,
    jstring run_segment,
    jstring server_segment,
    jstring start_name,
    jstring script_body
) {
    const CreateResult created = create_launch_script(
        jstring_to_string(env, home_dir),
        jstring_to_string(env, run_segment),
        jstring_to_string(env, server_segment),
        jstring_to_string(env, start_name),
        jstring_to_string(env, script_body)
    );
    if (!created.ok) return nullptr;
    jclass string_class = env->FindClass("java/lang/String");
    if (string_class == nullptr) return nullptr;
    jobjectArray result = env->NewObjectArray(2, string_class, nullptr);
    if (result == nullptr) return nullptr;
    env->SetObjectArrayElement(result, 0, env->NewStringUTF(created.host_path.c_str()));
    env->SetObjectArrayElement(result, 1, env->NewStringUTF(created.identity.c_str()));
    return result;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_anka_clawbot_SecureImportNative_deleteMcpLaunchDirectory(
    JNIEnv* env,
    jclass,
    jstring home_dir,
    jstring run_segment,
    jstring server_segment,
    jstring start_name,
    jstring expected_identity
) {
    const bool deleted = delete_launch_directory(
        jstring_to_string(env, home_dir),
        jstring_to_string(env, run_segment),
        jstring_to_string(env, server_segment),
        jstring_to_string(env, start_name),
        jstring_to_string(env, expected_identity)
    );
    return deleted ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_anka_clawbot_SecureImportNative_sweepMcpLaunchDirectories(
    JNIEnv* env,
    jclass,
    jstring home_dir,
    jlong max_age_ms,
    jobjectArray live_identities
) {
    std::vector<std::string> live;
    if (live_identities != nullptr) {
        const jsize count = env->GetArrayLength(live_identities);
        for (jsize index = 0; index < count; ++index) {
            auto entry = static_cast<jstring>(
                env->GetObjectArrayElement(live_identities, index)
            );
            if (entry == nullptr) continue;
            live.push_back(jstring_to_string(env, entry));
        }
    }
    return static_cast<jint>(sweep_launch_directories(
        jstring_to_string(env, home_dir),
        static_cast<long long>(max_age_ms),
        live
    ));
}

#endif  // MCP_LAUNCH_HOST_TEST
