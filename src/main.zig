const std = @import("std");
const warn = std.debug.warn;
const win = std.os.windows;
usingnamespace @import("externs.zig");

//usage: ./injector process-id absolute-path-of-dll
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const mem = &arena.allocator;

    const args = try std.process.argsAlloc(mem);
    defer std.process.argsFree(mem, args);
    if (args.len != 3) return error.ExpectedTwoArgs;

    const path = try std.unicode.utf8ToUtf16LeWithNull(mem, args[2]);
    defer mem.free(path);

    const pid = try std.fmt.parseInt(u32, args[1], 10);

    //if we encounter a winapi error, print its exit code before exit
    errdefer {
        @setEvalBranchQuota(5000);
        const err = win.kernel32.GetLastError();
        std.debug.warn("failed with code 0x{X}: {}\n", .{ @enumToInt(err), err });
    }

    //open target process with VM_WRITE, CREATE_THREAD, VM_OPERATION
    const process = OpenProcess(0x20 | 0x2 | 0x8, 0, pid) orelse return error.OpenProcessFailed;
    defer std.os.windows.CloseHandle(process);

    //allocate memory for the dll's path string in the target process
    const target_path = VirtualAllocEx(
        process,
        null,
        path.len,
        win.MEM_RESERVE | win.MEM_COMMIT,
        win.PAGE_READWRITE,
    ) orelse return error.TargetPathAllocationFailed;
    defer _ = VirtualFreeEx(process, target_path, 0, win.MEM_RELEASE);

    //copy path string from injector to target process in the newly allocated memory
    if (WriteProcessMemory(
        process,
        target_path,
        path.ptr,
        (path.len + 1) * 2,
        null
    ) == 0) return error.WPMPathCopyFailed;
    
    // 1) get a handle to kernel32.dll in the injector's process
    // 2) get address of LoadLibraryW inside kernel32
    // side note: kernel32 is loaded in the same place for all processes (of the same bitness), which is why this works
    // 3) create a thread in the target process starting in LoadLibraryW, with the path string as its argument
    const thread_handle = CreateRemoteThread(
        process,
        null,
        0,
        @ptrCast(
            fn (win.LPVOID) callconv(.C) u32,
            win.kernel32.GetProcAddress(
                GetModuleHandleA("kernel32.dll") orelse unreachable,
                "LoadLibraryW",
            ) orelse unreachable,
        ),
        target_path,
        0,
        null,
    ) orelse return error.ThreadCreationFailed;
    defer win.CloseHandle(thread_handle);

    try std.io.getStdOut().outStream().print("called LoadLibraryW\n", .{});
    //wait for LoadLibraryW to return and the thread to exit
    //this is needed so we don't prematurely deallocate the path string memory
    _ = win.kernel32.WaitForSingleObject(thread_handle, win.INFINITE);
    try std.io.getStdOut().outStream().print("finished injecting\n", .{});
}