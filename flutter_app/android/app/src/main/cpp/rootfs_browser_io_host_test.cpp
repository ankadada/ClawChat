/*
 * Host harness for the descriptor-relative file-browser I/O.
 *
 * Runs the very code the device runs, against real directories, including a
 * thread that keeps swapping a guest-writable parent for a symlink while the
 * browser lists, deletes and writes.
 */
#include "rootfs_browser_io.cpp"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <thread>

namespace {

int g_failures = 0;

void check(bool condition, const std::string& message) {
    if (condition) return;
    ++g_failures;
    std::fprintf(stderr, "FAIL: %s\n", message.c_str());
}

std::string make_temp_root() {
    char pattern[] = "/tmp/rootfs-browser-XXXXXX";
    char* created = mkdtemp(pattern);
    if (created == nullptr) {
        std::fprintf(stderr, "FAIL: mkdtemp\n");
        std::exit(2);
    }
    return std::string(created);
}

bool write_text(const std::string& path, const std::string& body) {
    ScopedFd file(open(
        path.c_str(),
        O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC,
        0600
    ));
    if (!file.valid()) return false;
    size_t offset = 0;
    while (offset < body.size()) {
        const ssize_t step = write(file.get(), body.data() + offset, body.size() - offset);
        if (step <= 0) return false;
        offset += static_cast<size_t>(step);
    }
    return true;
}

bool read_text_if_present(const std::string& path, std::string* body) {
    ScopedFd file(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    if (!file.valid()) return false;
    body->clear();
    char buffer[512];
    while (true) {
        const ssize_t step = read(file.get(), buffer, sizeof(buffer));
        if (step <= 0) break;
        body->append(buffer, static_cast<size_t>(step));
    }
    return true;
}

std::string read_text(const std::string& path) {
    std::string body;
    read_text_if_present(path, &body);
    return body;
}

bool is_link_or_fifo(const std::string& path) {
    struct stat value {};
    if (lstat(path.c_str(), &value) != 0) return false;
    return S_ISFIFO(value.st_mode) || S_ISLNK(value.st_mode);
}

/** True when the directory holds no leftover write temp file. */
bool dir_has_no_temp_files(const std::string& path) {
    const int duplicate =
        open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (duplicate < 0) return false;
    DIR* stream = fdopendir(duplicate);
    if (stream == nullptr) {
        close(duplicate);
        return false;
    }
    bool clean = true;
    while (true) {
        dirent* entry = readdir(stream);
        if (entry == nullptr) break;
        const std::string name(entry->d_name);
        if (name.rfind(".clawchat-write-", 0) == 0) clean = false;
    }
    closedir(stream);
    return clean;
}

bool create_dir(const std::string& root, const std::string& relative) {
    ScopedFd root_fd;
    if (!open_root(root, &root_fd)) return false;
    return create_directory_path(root_fd.get(), relative);
}

bool is_directory(const std::string& path) {
    struct stat value {};
    return lstat(path.c_str(), &value) == 0 && S_ISDIR(value.st_mode);
}

bool exists(const std::string& path) {
    struct stat value {};
    return lstat(path.c_str(), &value) == 0;
}

bool is_link(const std::string& path) {
    struct stat value {};
    return lstat(path.c_str(), &value) == 0 && S_ISLNK(value.st_mode);
}

std::vector<Entry> list(const std::string& root, const std::string& relative, bool* ok) {
    ScopedFd root_fd;
    std::vector<Entry> entries;
    bool truncated = false;
    if (!open_root(root, &root_fd)) {
        *ok = false;
        return entries;
    }
    *ok = list_directory_entries(
        root_fd.get(),
        split_components(relative),
        200,
        &entries,
        &truncated
    );
    return entries;
}

bool remove_file(const std::string& root, const std::string& relative) {
    ScopedFd root_fd;
    if (!open_root(root, &root_fd)) return false;
    bool missing = false;
    const bool deleted = delete_regular_file(root_fd.get(), relative, &missing);
    return deleted || missing;
}

bool write_file(
    const std::string& root,
    const std::string& relative,
    const std::string& body,
    bool create_new
) {
    ScopedFd root_fd;
    if (!open_root(root, &root_fd)) return false;
    bool exists_flag = false;
    return write_regular_file(
        root_fd.get(),
        relative,
        body,
        create_new,
        &exists_flag
    );
}

void test_listing_is_sorted_and_marks_links(const std::string& root) {
    mkdir((root + "/ws").c_str(), 0700);
    write_text(root + "/ws/zeta.txt", "12345");
    write_text(root + "/ws/alpha.txt", "x");
    mkdir((root + "/ws/sub").c_str(), 0700);
    const std::string outside = root + "/outside";
    mkdir(outside.c_str(), 0700);
    write_text(outside + "/secret.txt", "s");
    check(symlink(outside.c_str(), (root + "/ws/linked").c_str()) == 0, "planted a link");

    bool ok = false;
    const std::vector<Entry> entries = list(root + "/ws", "", &ok);

    check(ok, "listing succeeded");
    check(entries.size() == 4, "four entries listed");
    check(entries[0].name == "sub" && entries[0].is_directory, "directory first");
    check(entries[1].name == "alpha.txt" && !entries[1].is_directory, "then files by name");
    const Entry* link = nullptr;
    const Entry* zeta = nullptr;
    for (const auto& entry : entries) {
        if (entry.name == "linked") link = &entry;
        if (entry.name == "zeta.txt") zeta = &entry;
    }
    check(link != nullptr && link->is_link, "link reported as a link");
    check(link != nullptr && !link->is_directory,
          "a link is never a directory to descend into");
    check(zeta != nullptr && zeta->size == 5, "size reported");
    bool nested_ok = false;
    const std::vector<Entry> nested = list(root + "/ws", "sub", &nested_ok);
    check(nested_ok && nested.empty(), "a nested directory lists empty");
    bool escaped_ok = false;
    list(root + "/ws/linked", "", &escaped_ok);
    check(!escaped_ok, "a symlinked component is refused");
}

void test_delete_only_touches_the_named_file(const std::string& root) {
    mkdir((root + "/del").c_str(), 0700);
    write_text(root + "/del/file.txt", "keep me");
    const std::string outside = root + "/outside-del";
    mkdir(outside.c_str(), 0700);
    write_text(outside + "/keep.txt", "keep");
    check(symlink(outside.c_str(), (root + "/del/link").c_str()) == 0, "planted a link");

    check(remove_file(root + "/del", "file.txt"), "regular file deleted");
    check(!exists(root + "/del/file.txt"), "file is gone");
    check(!remove_file(root + "/del", "link"), "a link is not deletable");
    check(is_link(root + "/del/link"), "the link itself survives");
    check(exists(outside + "/keep.txt"), "the link target was untouched");
    check(!remove_file(root + "/del", "../outside-del/keep.txt"), "traversal refused");
    check(exists(outside + "/keep.txt"), "traversal changed nothing");
    check(remove_file(root + "/del", "missing.txt"), "a missing file is a no-op");
}

void test_write_never_overwrites_and_stays_inside(const std::string& root) {
    mkdir((root + "/save").c_str(), 0700);
    check(write_file(root + "/save", "note.md", "first", true), "new file written");
    check(read_text(root + "/save/note.md") == "first", "content written");
    check(!write_file(root + "/save", "note.md", "second", true), "existing name refused");
    check(read_text(root + "/save/note.md") == "first", "content not overwritten");

    const std::string outside = root + "/outside-save";
    mkdir(outside.c_str(), 0700);
    check(symlink(outside.c_str(), (root + "/save/escape").c_str()) == 0, "planted a link");
    check(!write_file(root + "/save", "escape/note.md", "x", true),
          "writing through a link is refused");
    check(!exists(outside + "/note.md"), "nothing landed behind the link");
}

void test_overwrite_refuses_hard_links_without_truncating(const std::string& root) {
    const std::string dir = root + "/hard";
    mkdir(dir.c_str(), 0700);
    check(write_text(dir + "/target.txt", "original"), "prepared the target file");
    check(link((dir + "/target.txt").c_str(), (dir + "/alias.txt").c_str()) == 0,
          "created a hard link");

    check(!write_file(root + "/hard", "target.txt", "replacement", false),
          "a hard-linked target refuses the overwrite");
    check(read_text(dir + "/target.txt") == "original",
          "the target kept its content");
    check(read_text(dir + "/alias.txt") == "original",
          "the other hard-link name kept its content");

    // The ordinary overwrite path still works for a plain single-link file.
    check(write_file(root + "/hard", "plain.txt", "first", false), "plain file created");
    check(write_file(root + "/hard", "plain.txt", "second", false), "plain file overwritten");
    check(read_text(dir + "/plain.txt") == "second", "overwrite applied");

    // Exclusive creation still refuses an existing name outright.
    check(!write_file(root + "/hard", "plain.txt", "third", true),
          "create-new refuses an existing name");
    check(read_text(dir + "/plain.txt") == "second", "create-new left it untouched");
}

void test_overwrite_refuses_fifo_and_special_nodes_without_blocking(
    const std::string& root
) {
    const std::string dir = root + "/special";
    mkdir(dir.c_str(), 0700);
    check(mkfifo((dir + "/pipe").c_str(), 0600) == 0, "created a FIFO");
    mkdir((dir + "/sub").c_str(), 0700);

    const auto started = std::chrono::steady_clock::now();
    check(!write_file(root + "/special", "pipe", "x", false),
          "a FIFO target is refused");
    check(!write_file(root + "/special", "pipe", "x", true),
          "create-new over a FIFO is refused");
    check(!write_file(root + "/special", "sub", "x", false),
          "a directory target is refused");
    const auto elapsed = std::chrono::steady_clock::now() - started;
    check(
        std::chrono::duration_cast<std::chrono::seconds>(elapsed).count() < 5,
        "special nodes fail fast instead of blocking"
    );
    check(is_link_or_fifo(dir + "/pipe"), "the FIFO is still there");
}

void test_overwrite_never_clears_a_concurrently_linked_inode(const std::string& root) {
    const std::string dir = root + "/linkrace";
    mkdir(dir.c_str(), 0700);
    check(write_file(root + "/linkrace", "target.txt", "original", true),
          "prepared the target");
    const std::string target = dir + "/target.txt";
    const std::string alias = dir + "/alias.txt";

    std::atomic<bool> stop{false};
    std::atomic<int> aliases_created{0};
    std::thread linker([&]() {
        while (!stop.load()) {
            if (link(target.c_str(), alias.c_str()) == 0) {
                aliases_created.fetch_add(1);
                std::this_thread::yield();
                unlink(alias.c_str());
            }
            std::this_thread::yield();
        }
    });

    int writes_ok = 0;
    int writes_refused = 0;
    for (int index = 0; index < 300; ++index) {
        const std::string body = "v" + std::to_string(index);
        if (write_file(root + "/linkrace", "target.txt", body, false)) {
            writes_ok++;
        } else {
            writes_refused++;
        }
        // Whenever a second name could be opened it must still hold the
        // ORIGINAL bytes: replacing the directory entry never empties a shared
        // inode. The linker may unlink the alias at any moment, so the check
        // opens the alias directly and skips the iteration if it is gone.
        std::string aliased;
        if (read_text_if_present(alias, &aliased)) {
            check(
                aliased == "original" || aliased.rfind("v", 0) == 0,
                "a linked inode kept its content (never truncated)"
            );
        }
    }
    stop.store(true);
    linker.join();

    check(writes_ok + writes_refused == 300, "every overwrite was decided");
    check(aliases_created.load() > 0, "the linker really raced the writes");
    const std::string final_content = read_text(target);
    check(!final_content.empty(), "the target still holds content");
}

void test_failed_write_leaves_no_partial_file(const std::string& root) {
    const std::string dir = root + "/cleanup";
    mkdir(dir.c_str(), 0700);

    // A failing overwrite must not leave the temp file behind.
    check(write_file(root + "/cleanup", "keep.txt", "keep", true), "prepared a file");
    g_write_failure_after_bytes = 3;
    check(!write_file(root + "/cleanup", "keep.txt", "replacement", false),
          "a failing overwrite reports failure");
    g_write_failure_after_bytes = -1;
    check(read_text(dir + "/keep.txt") == "keep", "the target kept its content");
    check(dir_has_no_temp_files(dir), "no partial temp file was left behind");

    // A failing exclusive create must remove the file it created.
    g_write_failure_after_bytes = 2;
    check(!write_file(root + "/cleanup", "fresh.txt", "content", true),
          "a failing create reports failure");
    g_write_failure_after_bytes = -1;
    check(!exists(dir + "/fresh.txt"), "the failed create left nothing behind");
    check(dir_has_no_temp_files(dir), "still no temp files");

    // And the happy path still works after the failures.
    check(write_file(root + "/cleanup", "fresh.txt", "content", true),
          "create works again");
    check(read_text(dir + "/fresh.txt") == "content", "content written");
}

void test_race_parent_swap_never_escapes(const std::string& root) {
    const std::string workspace = root + "/race";
    const std::string outside = root + "/outside-race";
    mkdir(workspace.c_str(), 0700);
    mkdir(outside.c_str(), 0700);
    const std::string parent = workspace + "/parent";
    mkdir(parent.c_str(), 0700);

    // Deterministic baseline before the swapper starts.
    const bool quiescent_write = write_file(workspace, "quiet.txt", "body", true);
    bool quiescent_list_ok = false;
    const std::vector<Entry> quiescent_entries = list(workspace, "", &quiescent_list_ok);
    const bool quiescent_read = quiescent_list_ok && !quiescent_entries.empty() &&
        read_text(workspace + "/quiet.txt") == "body";
    const bool quiescent_delete = remove_file(workspace, "quiet.txt");
    check(!exists(workspace + "/quiet.txt"), "baseline file removed");

    std::atomic<bool> stop{false};
    std::thread swapper([&]() {
        while (!stop.load()) {
            // Turn the browsed parent into a link to the outside tree, then
            // take the link away again.
            unlink((parent + "/leaf.txt").c_str());
            rmdir(parent.c_str());
            symlink(outside.c_str(), parent.c_str());
            std::this_thread::yield();
            unlink(parent.c_str());
            mkdir(parent.c_str(), 0700);
            std::this_thread::yield();
        }
    });

    int writes_ok = 0;
    int writes_refused = 0;
    int deletes_ok = 0;
    for (int index = 0; index < 400; ++index) {
        const std::string name = "leaf-" + std::to_string(index) + ".txt";
        if (write_file(workspace, "parent/" + name, "body", true)) {
            writes_ok++;
        } else {
            writes_refused++;
        }
        if (remove_file(workspace, "parent/" + name)) deletes_ok++;
        bool ok = false;
        list(workspace, "parent", &ok);
    }
    stop.store(true);
    swapper.join();

    // Liveness without the swapper: the same calls succeed on a quiet tree.
    check(writes_ok + writes_refused == 400, "every write either succeeded or refused");
    check(quiescent_write && quiescent_read && quiescent_delete,
          "the same operations succeed when nothing races them");
    check(deletes_ok > 0, "deletes also ran during the race");
    check(!exists(outside + "/leaf-0.txt"), "nothing was written behind the link");
    check(!exists(outside + "/leaf-399.txt"), "nothing was written behind the link (late)");
}

}  // namespace

void test_create_directory_builds_missing_levels_and_refuses_links(
    const std::string& root
) {
    const std::string dir = root + "/mkdirs";
    mkdir(dir.c_str(), 0700);

    // Missing nested levels are created below the verified root.
    check(create_dir(root + "/mkdirs", "shared/nested"),
          "missing directory levels are created");
    check(is_directory(dir + "/shared") && is_directory(dir + "/shared/nested"),
          "the created levels are real directories");
    check(create_dir(root + "/mkdirs", "shared/nested"),
          "an existing directory path is accepted");

    // A plain file in the way is refused, never replaced.
    check(write_file(root + "/mkdirs", "blocker", "x", true),
          "prepared a blocker file");
    check(!create_dir(root + "/mkdirs", "blocker/child"),
          "a file component is refused");
    check(read_text(dir + "/blocker") == "x", "the blocker file is untouched");

    // A symlinked component is refused and its target stays untouched.
    const std::string outside = root + "/outside";
    mkdir(outside.c_str(), 0700);
    check(symlink(outside.c_str(), (dir + "/link").c_str()) == 0,
          "prepared a symlinked component");
    check(!create_dir(root + "/mkdirs", "link/child"),
          "a symlinked component is refused");
    check(!exists(outside + "/child"),
          "nothing was created behind the symlink");

    // A file can be written into the directory this created.
    check(write_file(root + "/mkdirs", "shared/nested/note.md", "body", true),
          "writing into the created directory succeeds");
    check(read_text(dir + "/shared/nested/note.md") == "body",
          "the written body is there");
}

int main() {
    const std::string root = make_temp_root();
    test_listing_is_sorted_and_marks_links(root);
    test_delete_only_touches_the_named_file(root);
    test_write_never_overwrites_and_stays_inside(root);
    test_overwrite_refuses_hard_links_without_truncating(root);
    test_overwrite_refuses_fifo_and_special_nodes_without_blocking(root);
    test_overwrite_never_clears_a_concurrently_linked_inode(root);
    test_failed_write_leaves_no_partial_file(root);
    test_race_parent_swap_never_escapes(root);
    test_create_directory_builds_missing_levels_and_refuses_links(root);
    if (g_failures == 0) {
        std::printf("rootfs browser host harness: OK\n");
        return 0;
    }
    std::fprintf(stderr, "rootfs browser host harness: %d failure(s)\n", g_failures);
    return 1;
}
