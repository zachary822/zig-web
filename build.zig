const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // The server sends `static/` itself, in development and in production.
    // Use -Dserve-static=false if a different server (for example nginx)
    // sends the static files.
    const serve_static = b.option(
        bool,
        "serve-static",
        "Serve /static/ from the static/ directory (default: true)",
    ) orelse true;
    // MariaDB support is optional. By default it is included when pkg-config
    // finds MariaDB Connector/C (libmariadb). Install it with
    // `apt install libmariadb-dev` (Debian, Raspberry Pi OS) or
    // `brew install mariadb-connector-c` (macOS).
    const db = b.option(
        bool,
        "db",
        "Include MariaDB support (default: true when pkg-config finds libmariadb)",
    ) orelse hasPkgConfig(b, "libmariadb");

    const options = b.addOptions();
    options.addOption(bool, "serve_static", serve_static);
    const build_options = options.createModule();

    // The database client (../zig-db), with or without MariaDB support.
    const zig_db = b.dependency("zig_db", .{
        .target = target,
        .optimize = optimize,
        .mariadb = db,
    });
    const db_module = zig_db.module("db");

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const mustache = b.dependency("mustache_zig", .{
        .target = target,
        .optimize = optimize,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zig_web",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                .{ .name = "httpz", .module = httpz.module("httpz") },
                .{ .name = "mustache", .module = mustache.module("mustache_zig") },
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    exe.root_module.addImport("db", db_module);

    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    // Compiles src/input.css to static/css/style.css with the Tailwind
    // CLI from node_modules (run `npm install` first). During development,
    // `npm run css:watch` rebuilds the CSS on every change instead.
    const css_step = b.step("css", "Build the Tailwind CSS");
    const css_cmd = b.addSystemCommand(&.{ "npm", "run", "--silent", "css:build" });
    css_cmd.setCwd(b.path("."));
    css_step.dependOn(&css_cmd.step);

    // Database migrations: a separate program that applies the SQL files in
    // migrations/. `zig build migrate` applies pending migrations; pass a
    // command after `--`, for example `zig build migrate -- status` or
    // `zig build migrate -- new create_posts`. It runs from the project root
    // and reads .env like the server.
    const migrate_exe = b.addExecutable(.{
        .name = "zig_web_migrate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/migrate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });
    migrate_exe.root_module.addImport("db", db_module);
    b.installArtifact(migrate_exe);

    const migrate_step = b.step("migrate", "Apply database migrations (zig build migrate -- status|new NAME)");
    const migrate_cmd = b.addRunArtifact(migrate_exe);
    migrate_cmd.setCwd(b.path("."));
    migrate_cmd.addPassthruArgs();
    migrate_step.dependOn(&migrate_cmd.step);

    // User accounts: a separate program, because the app has no
    // registration page. `zig build user -- create USERNAME EMAIL` adds a
    // user and asks for the password; see src/user.zig for all commands.
    const user_exe = b.addExecutable(.{
        .name = "zig_web_user",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });
    user_exe.root_module.addImport("db", db_module);
    b.installArtifact(user_exe);

    const user_step = b.step("user", "Manage users (zig build user -- create USERNAME EMAIL|passwd USERNAME|list)");
    const user_cmd = b.addRunArtifact(user_exe);
    user_cmd.setCwd(b.path("."));
    // The password prompt reads from the terminal.
    user_cmd.stdio = .inherit;
    user_cmd.addPassthruArgs();
    user_step.dependOn(&user_cmd.step);

    // Uploaded files: `zig build media -- check` shows the files in
    // MEDIA_DIR without rows and the rows without files, and `prune`
    // deletes old files without rows; see src/media_cli.zig.
    const media_exe = b.addExecutable(.{
        .name = "zig_web_media",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/media_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });
    media_exe.root_module.addImport("db", db_module);
    b.installArtifact(media_exe);

    const media_step = b.step("media", "Examine uploaded files (zig build media -- check|prune)");
    const media_cmd = b.addRunArtifact(media_exe);
    media_cmd.setCwd(b.path("."));
    // The files in MEDIA_DIR are not inputs of the step, so it runs each time.
    media_cmd.has_side_effects = true;
    media_cmd.stdio = .inherit;
    media_cmd.addPassthruArgs();
    media_step.dependOn(&media_cmd.step);

    // collectstatic: copies static/ to STATIC_ROOT for nginx, with a content
    // hash in the file names; see src/collectstatic.zig. `zig build
    // collectstatic -- DIR` copies to DIR. It runs from the project root and
    // reads .env like the server. Run it after `zig build css`.
    const collectstatic_exe = b.addExecutable(.{
        .name = "zig_web_collectstatic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/collectstatic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "httpz", .module = httpz.module("httpz") },
                .{ .name = "mustache", .module = mustache.module("mustache_zig") },
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });
    b.installArtifact(collectstatic_exe);

    const collectstatic_step = b.step("collectstatic", "Copy static files with hashed names to STATIC_ROOT (zig build collectstatic -- [DIR])");
    const collectstatic_cmd = b.addRunArtifact(collectstatic_exe);
    collectstatic_cmd.setCwd(b.path("."));
    // The files in static/ are not inputs of the step, so it runs each time.
    collectstatic_cmd.has_side_effects = true;
    collectstatic_cmd.stdio = .inherit;
    collectstatic_cmd.addPassthruArgs();
    collectstatic_step.dependOn(&collectstatic_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the executable's
    // root module.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);
    // The tests read the templates at run time. With the templates as
    // inputs, a template change runs the tests again (not a cached result).
    addTemplateInputs(b, run_exe_tests);
    const migrate_tests = b.addTest(.{
        .root_module = migrate_exe.root_module,
    });
    const run_migrate_tests = b.addRunArtifact(migrate_tests);
    const user_tests = b.addTest(.{
        .root_module = user_exe.root_module,
    });
    const run_user_tests = b.addRunArtifact(user_tests);
    const media_tests = b.addTest(.{
        .root_module = media_exe.root_module,
    });
    const run_media_tests = b.addRunArtifact(media_tests);
    const collectstatic_tests = b.addTest(.{
        .root_module = collectstatic_exe.root_module,
    });
    const run_collectstatic_tests = b.addRunArtifact(collectstatic_tests);

    // A top level step for running all tests.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_migrate_tests.step);
    test_step.dependOn(&run_user_tests.step);
    test_step.dependOn(&run_media_tests.step);
    test_step.dependOn(&run_collectstatic_tests.step);

    // Tests that need a database skip unless TEST_DATABASE_URL is set (for
    // example to DATABASE_URL); they use temporary tables only. This step runs
    // the server tests each time, because the result depends on the database
    // and the cache key does not include the environment. Do not set the
    // variable with `setEnvironmentVariable`: the build keeps the configured
    // environment, so the tests would get an old value.
    //
    //     TEST_DATABASE_URL=mariadb://... zig build test-db
    const run_db_tests = b.addRunArtifact(exe_tests);
    run_db_tests.has_side_effects = true;
    const test_db_step = b.step("test-db", "Run the server tests, with the database tests (needs TEST_DATABASE_URL)");
    test_db_step.dependOn(&run_db_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

/// Reports whether pkg-config finds the library `name`.
fn hasPkgConfig(b: *std.Build, name: []const u8) bool {
    var exit_code: u8 = undefined;
    _ = b.runAllowFail(&.{ "pkg-config", "--exists", name }, &exit_code, .ignore) catch return false;
    return true;
}

/// Adds each file in templates/ as an input of `run`.
fn addTemplateInputs(b: *std.Build, run: *std.Build.Step.Run) void {
    const io = b.graph.io;
    var dir = b.root.openDir(io, "templates", .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open templates/: {t}", .{err});
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read templates/: {t}", .{err})) |entry| {
        if (entry.kind != .file) continue;
        run.addFileInput(b.path(b.fmt("templates/{s}", .{entry.name})));
    }
}
