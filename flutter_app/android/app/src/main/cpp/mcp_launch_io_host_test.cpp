/*
 * Host harness for the descriptor-relative MCP launch I/O.
 *
 * The device runs these functions through JNI, which a JVM unit test cannot
 * call. This harness includes the very same translation unit (with
 * -DMCP_LAUNCH_HOST_TEST) and drives it against real directories, including a
 * thread that keeps swapping a guest-writable parent for a symlink, so the race
 * the reviewer flagged is executed rather than only reviewed.
 */
#include "mcp_launch_io.cpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <vector>

namespace {

int g_failures = 0;

void check(bool condition, const std::string& message) {
    if (condition) return;
    ++g_failures;
    std::fprintf(stderr, "FAIL: %s\n", message.c_str());
}

std::string make_temp_root() {
    char pattern[] = "/tmp/mcp-launch-host-XXXXXX";
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
    return write_all(file.get(), body);
}

std::string read_text(const std::string& path) {
    ScopedFd file(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    if (!file.valid()) return std::string();
    std::string body;
    char buffer[512];
    while (true) {
        const ssize_t step = read(file.get(), buffer, sizeof(buffer));
        if (step <= 0) break;
        body.append(buffer, static_cast<size_t>(step));
    }
    return body;
}

bool exists(const std::string& path) {
    struct stat value {};
    return lstat(path.c_str(), &value) == 0;
}

bool is_link(const std::string& path) {
    struct stat value {};
    return lstat(path.c_str(), &value) == 0 && S_ISLNK(value.st_mode);
}

int count_entries(const std::string& path) {
    const int duplicate =
        open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (duplicate < 0) return -1;
    DIR* stream = fdopendir(duplicate);
    if (stream == nullptr) {
        close(duplicate);
        return -1;
    }
    int count = 0;
    while (true) {
        dirent* entry = readdir(stream);
        if (entry == nullptr) break;
        const std::string name(entry->d_name);
        if (name == "." || name == "..") continue;
        count++;
    }
    closedir(stream);
    return count;
}

void age_path(const std::string& path, long long seconds_ago) {
    struct timespec times[2];
    const long long now_seconds = static_cast<long long>(time(nullptr));
    times[0].tv_sec = now_seconds - seconds_ago;
    times[0].tv_nsec = 0;
    times[1].tv_sec = now_seconds - seconds_ago;
    times[1].tv_nsec = 0;
    (void)utimensat(AT_FDCWD, path.c_str(), times, AT_SYMLINK_NOFOLLOW);
}

CreateResult create(
    const std::string& home,
    const std::string& run,
    const std::string& server,
    const std::string& start,
    const std::string& body = "#!/bin/sh\nexit 0\n"
) {
    return create_launch_script(home, run, server, start, body);
}

// Deterministic replacement seam: the hook runs right before a final rmdir and
// swaps the emptied target for a different empty directory or a symlink, which
// is exactly the race the identity re-check must refuse.
std::string g_hook_target_name;
std::string g_hook_target_path;
std::string g_hook_symlink_to;
std::atomic<bool> g_hook_fired{false};

void replace_target_hook(int, const char* name) {
    if (g_hook_target_name.empty() || g_hook_fired.load()) return;
    if (g_hook_target_name != name) return;
    g_hook_fired.store(true);
    rmdir(g_hook_target_path.c_str());
    if (g_hook_symlink_to.empty()) {
        mkdir(g_hook_target_path.c_str(), 0700);
    } else {
        symlink(g_hook_symlink_to.c_str(), g_hook_target_path.c_str());
    }
}

void arm_replacement_hook(
    const std::string& name,
    const std::string& path,
    const std::string& symlink_to = std::string()
) {
    g_hook_target_name = name;
    g_hook_target_path = path;
    g_hook_symlink_to = symlink_to;
    g_hook_fired.store(false);
    set_before_final_rmdir_hook(replace_target_hook);
}

void reset_replacement_hook() {
    g_hook_target_name.clear();
    g_hook_target_path.clear();
    g_hook_symlink_to.clear();
    g_hook_fired.store(false);
    set_before_final_rmdir_hook(nullptr);
}

void test_create_and_delete_round_trip(const std::string& root) {
    const std::string home = root + "/home";
    const CreateResult created = create(home, "run", "server", "start-one");
    check(created.ok, "create succeeded: " + created.error);
    check(exists(created.host_path), "script exists at the reported path");
    check(read_text(created.host_path) == "#!/bin/sh\nexit 0\n", "script body written");
    check(!created.identity.empty(), "identity reported");

    struct stat value {};
    check(stat(created.host_path.c_str(), &value) == 0 && (value.st_mode & 0777) == 0700,
          "script is owner-only");

    // A second start in the same chain gets its own directory.
    const CreateResult second = create(home, "run", "server", "start-two");
    check(second.ok && second.host_path != created.host_path,
          "second start is a distinct directory");
    check(second.identity != created.identity, "second start has its own identity");
    check(read_text(second.host_path).find("exit 0") != std::string::npos,
          "second script has its own body");

    check(delete_launch_directory(home, "run", "server", "start-one", created.identity),
          "delete removes the start directory");
    check(!exists(created.host_path), "script gone after delete");
    check(exists(second.host_path), "the other start survives");

    // A substituted directory is never deleted through.
    const std::string outside = root + "/outside";
    mkdir(outside.c_str(), 0700);
    write_text(outside + "/keep.txt", "keep");
    const std::string second_dir = home + "/.mcp/run/server/start-two";
    check(unlink(second.host_path.c_str()) == 0, "script removed for the substitution check");
    check(rmdir(second_dir.c_str()) == 0, "start directory removed");
    check(symlink(outside.c_str(), second_dir.c_str()) == 0, "planted a symlinked start dir");
    check(!delete_launch_directory(home, "run", "server", "start-two", second.identity),
          "delete refuses a substituted start directory");
    check(exists(outside + "/keep.txt"), "nothing behind the link was deleted");
    check(is_link(second_dir), "the planted link was left alone");
}

void test_create_refuses_symlinked_levels(const std::string& root) {
    const std::string outside = root + "/outside-levels";
    mkdir(outside.c_str(), 0700);
    write_text(outside + "/keep.txt", "keep");

    const std::string home_one = root + "/home-one";
    const std::string home_two = root + "/home-two";
    const std::string home_three = root + "/home-three";
    const std::vector<std::string> homes{home_one, home_two, home_three};
    const std::vector<std::string> links{
        home_one + "/.mcp",
        home_two + "/.mcp/run",
        home_three + "/.mcp/run/server",
    };
    const std::vector<std::string> labels{"mcp root", "run level", "server level"};

    mkdir(home_one.c_str(), 0700);
    mkdir(home_two.c_str(), 0700);
    mkdir((home_two + "/.mcp").c_str(), 0700);
    mkdir(home_three.c_str(), 0700);
    mkdir((home_three + "/.mcp").c_str(), 0700);
    mkdir((home_three + "/.mcp/run").c_str(), 0700);

    for (size_t index = 0; index < links.size(); ++index) {
        check(symlink(outside.c_str(), links[index].c_str()) == 0,
              "planted a link at the " + labels[index]);
        const CreateResult created = create(homes[index], "run", "server", "start");
        check(!created.ok, "create refused the symlinked " + labels[index]);
        check(count_entries(outside) == 1,
              "nothing was written outside through the " + labels[index]);
        check(unlink(links[index].c_str()) == 0, "cleaned the planted link");
    }
}

void test_race_parent_swap_never_writes_outside(const std::string& root) {
    const std::string home = root + "/home-race";
    const std::string outside = root + "/outside-race";
    mkdir(home.c_str(), 0700);
    mkdir(outside.c_str(), 0700);
    const std::string start_dir = home + "/.mcp/run/server/start";
    const std::string start_script = start_dir + "/launch.sh";

    std::atomic<bool> stop{false};
    std::atomic<int> swaps{0};
    std::thread swapper([&]() {
        while (!stop.load()) {
            // Turn the start directory into a link to the outside tree, then
            // take the link away again. A create that resolves the path by
            // name must refuse instead of writing through the link.
            unlink(start_script.c_str());
            rmdir(start_dir.c_str());
            if (symlink(outside.c_str(), start_dir.c_str()) == 0) {
                swaps.fetch_add(1);
            }
            std::this_thread::yield();
            unlink(start_dir.c_str());
            std::this_thread::yield();
        }
    });

    int successes = 0;
    int refusals = 0;
    for (int index = 0; index < 600; ++index) {
        const CreateResult created = create(home, "run", "server", "start");
        if (created.ok) {
            successes++;
            check(created.host_path.rfind(home + "/.mcp/", 0) == 0,
                  "an accepted script stayed inside the home tree");
        } else {
            refusals++;
        }
    }
    stop.store(true);
    swapper.join();

    check(successes + refusals == 600, "every create either succeeded or refused");
    check(successes > 0, "the racy loop still created scripts");
    check(refusals > 0, "the racy loop also refused swapped components");
    check(swaps.load() > 0, "the swapper planted at least one link");
    // The whole point: nothing was ever written through the planted link.
    check(count_entries(outside) == 0, "the link target never received a script");
    check(!exists(outside + "/server"), "the link target never received the chain");
}

void test_sweep_unlinks_and_spares(const std::string& root) {
    const std::string home = root + "/home-sweep";
    const std::string outside = root + "/outside-sweep";
    mkdir(home.c_str(), 0700);
    mkdir(outside.c_str(), 0700);
    write_text(outside + "/keep.txt", "keep");

    const CreateResult stale = create(home, "run-old", "server", "stale-start");
    const CreateResult live = create(home, "run-live", "server", "live-start");
    const CreateResult fresh = create(home, "run-fresh", "server", "fresh-start");
    check(stale.ok && live.ok && fresh.ok, "prepared the sweep fixtures");

    const std::string stale_dir = home + "/.mcp/run-old/server/stale-start";
    check(symlink(outside.c_str(), (stale_dir + "/escape").c_str()) == 0,
          "planted a link inside the stale start directory");
    // Age both the stale and the live start: only the identity keeps the live
    // one, which is what the sweep must honour.
    age_path(stale_dir, 7200);
    age_path(home + "/.mcp/run-live/server/live-start", 7200);

    check(symlink(outside.c_str(), (home + "/.mcp/run-link").c_str()) == 0,
          "planted a symlinked run level");
    check(symlink(outside.c_str(), (home + "/.mcp/run-fresh/server/linked-start").c_str()) == 0,
          "planted a symlinked start node");

    const std::vector<std::string> live_identities{live.identity};
    const int removed = sweep_launch_directories(home, 3'600'000LL, live_identities);

    // Stale start + symlinked start node + symlinked run level.
    check(removed == 3, "sweep removed the stale, the linked start and the linked run");
    check(!exists(stale_dir), "the stale start directory was removed");
    check(exists(live.host_path), "the live start was kept by identity");
    check(exists(fresh.host_path), "the fresh start was kept by age");
    check(!is_link(home + "/.mcp/run-link"), "the symlinked run level was unlinked");
    check(!is_link(home + "/.mcp/run-fresh/server/linked-start"),
          "the symlinked start node was unlinked");
    check(exists(outside + "/keep.txt"), "nothing behind a link was deleted");
    check(read_text(outside + "/keep.txt") == "keep", "the link target content is intact");
    check(delete_launch_directory(home, "run-old", "server", "stale-start", stale.identity),
          "deleting an already swept directory is a no-op success");
}

void test_create_body_and_segment_limits(const std::string& root) {
    const std::string home = root + "/home-limits";
    const CreateResult huge =
        create(home, "run", "server", "start", std::string(kMaxBodyBytes + 1, 'x'));
    check(!huge.ok, "an oversized script body is refused");
    const CreateResult bad_segment = create(home, "../escape", "server", "start");
    check(!bad_segment.ok, "an unsafe run segment is refused");
    const CreateResult bad_start = create(home, "run", "server", "start/escape");
    check(!bad_start.ok, "an unsafe start name is refused");
}

void test_delete_refuses_a_replaced_directory(const std::string& root) {
    const std::string home = root + "/home-delete-replace";
    const CreateResult created = create(home, "run", "server", "start-replace");
    check(created.ok, "created the start for the delete replacement test");
    const std::string start_dir = home + "/.mcp/run/server/start-replace";

    arm_replacement_hook("start-replace", start_dir);
    const bool deleted = delete_launch_directory(
        home,
        "run",
        "server",
        "start-replace",
        created.identity
    );
    const bool fired = g_hook_fired.load();
    reset_replacement_hook();

    check(fired, "the delete replacement hook fired before the final rmdir");
    check(!deleted, "delete refuses a directory replaced after it was cleared");
    check(exists(start_dir), "the replacement empty directory was left alone");
    rmdir(start_dir.c_str());
}

void test_delete_unlinks_a_replaced_symlink(const std::string& root) {
    const std::string home = root + "/home-delete-link";
    const std::string outside = root + "/outside-delete-link";
    mkdir(outside.c_str(), 0700);
    write_text(outside + "/keep.txt", "keep");
    const CreateResult created = create(home, "run", "server", "start-link");
    check(created.ok, "created the start for the delete symlink test");
    const std::string start_dir = home + "/.mcp/run/server/start-link";

    arm_replacement_hook("start-link", start_dir, outside);
    const bool deleted = delete_launch_directory(
        home,
        "run",
        "server",
        "start-link",
        created.identity
    );
    const bool fired = g_hook_fired.load();
    reset_replacement_hook();

    check(fired, "the delete symlink hook fired before the final rmdir");
    check(deleted, "a replaced symlink is removed through the safe unlink path");
    check(!exists(start_dir), "the planted link node is gone");
    check(exists(outside + "/keep.txt"), "nothing behind the link was deleted");
    check(read_text(outside + "/keep.txt") == "keep", "the link target is intact");
}

void test_sweep_refuses_a_replaced_directory(const std::string& root) {
    const std::string home = root + "/home-sweep-replace";
    const CreateResult stale =
        create(home, "sweep-replace-run", "server", "sweep-replace-start");
    check(stale.ok, "created the start for the sweep replacement test");
    const std::string start_dir =
        home + "/.mcp/sweep-replace-run/server/sweep-replace-start";
    age_path(start_dir, 7200);

    arm_replacement_hook("sweep-replace-start", start_dir);
    const int removed = sweep_launch_directories(home, 3'600'000LL, {});
    const bool fired = g_hook_fired.load();
    reset_replacement_hook();

    check(fired, "the sweep replacement hook fired before the final rmdir");
    check(removed == 0, "the sweep does not count a replaced directory as removed");
    check(exists(start_dir), "the replacement directory survives the sweep");
    rmdir(start_dir.c_str());
}

void test_race_delete_never_unlinks_outside(const std::string& root) {
    const std::string home = root + "/home-delete-race";
    const std::string outside = root + "/outside-delete-race";
    mkdir(outside.c_str(), 0700);
    write_text(outside + "/keep.txt", "keep");
    const std::string start_dir = home + "/.mcp/run/server/start-delete-race";

    std::atomic<bool> stop{false};
    std::thread swapper([&]() {
        while (!stop.load()) {
            rmdir(start_dir.c_str());
            symlink(outside.c_str(), start_dir.c_str());
            std::this_thread::yield();
            unlink(start_dir.c_str());
            mkdir(start_dir.c_str(), 0700);
            std::this_thread::yield();
        }
    });

    for (int index = 0; index < 200; ++index) {
        const CreateResult created = create(home, "run", "server", "start-delete-race");
        if (!created.ok) continue;
        delete_launch_directory(
            home,
            "run",
            "server",
            "start-delete-race",
            created.identity
        );
    }
    stop.store(true);
    swapper.join();

    check(exists(outside + "/keep.txt"), "the delete race never removed the link target");
    check(read_text(outside + "/keep.txt") == "keep", "the link target content survives");
    check(count_entries(outside) == 1, "nothing was created or deleted outside");
}

}  // namespace

int main() {
    const std::string root = make_temp_root();
    test_create_and_delete_round_trip(root);
    test_create_refuses_symlinked_levels(root);
    test_race_parent_swap_never_writes_outside(root);
    test_sweep_unlinks_and_spares(root);
    test_create_body_and_segment_limits(root);
    test_delete_refuses_a_replaced_directory(root);
    test_delete_unlinks_a_replaced_symlink(root);
    test_sweep_refuses_a_replaced_directory(root);
    test_race_delete_never_unlinks_outside(root);
    if (g_failures == 0) {
        std::printf("mcp launch host harness: OK\n");
        return 0;
    }
    std::fprintf(stderr, "mcp launch host harness: %d failure(s)\n", g_failures);
    return 1;
}
