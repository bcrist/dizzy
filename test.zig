
fn single_param_empty_struct(a: Injectable_Thing_A) void {
    std.log.info("Called single_param_empty_struct({any})\n", .{ a });
}

fn two_params(b: Injectable_Thing_B, a: Injectable_Thing_A) !void {
    std.log.info("Called two_params({any}, {any})\n", .{ b, a });
}

fn thing_c(c: Injectable_Thing_C) !void {
    std.log.info("Called thing_c({s})\n", .{ c.msg });
}

fn thing_c2_error(_: Injectable_Thing_C2) !void {
    return error.Expected;
}

fn things_a_and_d(a: Injectable_Thing_A, d: Injectable_Thing_D) void {
    std.log.info("Called things_a_and_d({any}, {any})\n", .{ a, d });
}

test "basic usage" {
    const Injector = dizzy.Injector(providers, .{});

    try Injector.call(single_param_empty_struct, {});
    try Injector.call(two_params, {});
    try Injector.call(thing_c, {});

    try std.testing.expectError(error.Expected, Injector.call(thing_c2_error, {}));

    const Ext = Injector.extend(ext_providers);

    try Ext.call(things_a_and_d, {});
}

test "inputs/outputs" {
    const Msg = struct {
        msg: []const u8,

        pub fn func(self: @This()) usize {
            return self.msg.len;
        }
    };
    const Injector = dizzy.Injector(struct {}, .{
        .Input_Type = Msg,
        .Output_Type = usize,
        .Error_Type = error{},
    });

    try std.testing.expectEqual(9, Injector.call(Msg.func, .{ .msg = "Hellorld!" }));
}

test "Noninjectable" {
    const Msg = struct {
        msg: []const u8,

        pub const is_injectable = false;

        pub fn func1() usize {
            return 1;
        }

        pub fn func2(_: ?i32) usize {
            return 1;
        }

        pub fn func3(_: i32) usize {
            return 1;
        }

        pub fn func4(_: void) usize {
            return 1;
        }

        pub fn func5(_: []const u8) usize {
            return 1;
        }

        pub fn func6(self: @This()) usize {
            return self.msg.len;
        }

    };
    const Injector = dizzy.Injector(struct {}, .{
        .Input_Type = Msg,
        .Output_Type = usize,
        .Error_Type = error{},
    });

    try std.testing.expectEqual(1, Injector.call(Msg.func1, .{ .msg = "Hellorld!" }));
    
    // uncommenting any of these lines should cause a compile error, e.g. void is not injectable
    //try std.testing.expectEqual(9, Injector.call(Msg.func2, .{ .msg = "Hellorld!" }));
    //try std.testing.expectEqual(9, Injector.call(Msg.func3, .{ .msg = "Hellorld!" }));
    //try std.testing.expectEqual(9, Injector.call(Msg.func4, .{ .msg = "Hellorld!" }));
    //try std.testing.expectEqual(9, Injector.call(Msg.func5, .{ .msg = "Hellorld!" }));
    //try std.testing.expectEqual(9, Injector.call(Msg.func6, .{ .msg = "Hellorld!" }));
}


const Union_Result_Type = union(enum) {
    int: i32,
    unsigned: usize,
};

const Union_Result_Type2 = union(enum) {
    int: i32,
};

fn returns_i32() i32 {
    return -3;
}

fn returns_usize() usize {
    return 0;
}

fn returns_union() Union_Result_Type {
    return .{ .int = 1234 };
}

fn returns_union2() Union_Result_Type2 {
    return .{ .int = 1234 };
}

test "Union result coercion" {
    const Injector = dizzy.Injector(providers, .{ .Output_Type = Union_Result_Type });

    try std.testing.expectEqual(Union_Result_Type { .int = -3 }, try Injector.call(returns_i32, {}));
    try std.testing.expectEqual(Union_Result_Type { .unsigned = 0 }, try Injector.call(returns_usize, {}));
    try std.testing.expectEqual(Union_Result_Type { .int = 1234 }, try Injector.call(returns_union, {}));
    try std.testing.expectEqual(Union_Result_Type { .int = 1234 }, try Injector.call(returns_union2, {}));
}

const Injectable_Thing_A = struct {};

const Injectable_Thing_B = struct {
    value: i32,
};

const Injectable_Thing_C = struct {
    msg: []const u8,
};
const Injectable_Thing_C2 = struct {
    msg: []const u8,
};

const Injectable_Thing_D = struct {
    b: Injectable_Thing_B,
};

const providers = struct {

    pub fn inject_thing_a() Injectable_Thing_A {
        return .{};
    }

    pub fn inject_thing_b(_: void) anyerror!Injectable_Thing_B {
        return .{
            .value = 47,
        };
    }

    pub fn inject_thing_c(_: void) anyerror!Injectable_Thing_C {
        return .{
            .msg = try std.testing.allocator.dupe(u8, "Hellorld!"),
        };
    }
    pub fn inject_thing_c_cleanup(c: Injectable_Thing_C) void {
        std.testing.allocator.free(c.msg);
    }

    pub fn inject_thing_c2() !Injectable_Thing_C2 {
        return .{
            .msg = try std.testing.allocator.dupe(u8, "Hellorld!"),
        };
    }
    pub fn inject_thing_c2_cleanup_err(c: Injectable_Thing_C2) void {
        std.testing.allocator.free(c.msg);
    }

};

const ext_providers = struct {
    pub fn inject_thing_d(b: Injectable_Thing_B) Injectable_Thing_D {
        return .{ .b = b };
    }
};

const log = std.log.scoped(.dizzy);

const dizzy = @import("dizzy");
const std = @import("std");
