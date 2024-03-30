pub const Injector_Options = struct {
    Input_Type: type = void,
    Output_Type: type = void,
    Error_Type: type = anyerror,
};
pub fn Injector(comptime Provider_Decls: type, comptime options: Injector_Options) type {
    const providers = parse_providers(Provider_Decls, options.Input_Type, options.Error_Type, &.{});
    return Injector_Internal(providers, options.Input_Type, options.Output_Type, options.Error_Type);
}

pub const Provider_Mapping = struct {
    T: type,
    provider: *const anyopaque,
    err_cleanup: ?*const anyopaque,
    cleanup: ?*const anyopaque,
};
fn Injector_Internal(comptime providers: []const Provider_Mapping, comptime Input: type, comptime Output: type, comptime Error: type) type {
    return struct {
        pub fn call(func: anytype, data: Input) Error!Output {
            @setEvalBranchQuota(10_000); // you may need to increase this even more if you have lots of providers and/or parameters
            const Func = switch (@typeInfo(@TypeOf(func))) {
                .Fn => @TypeOf(func),
                .Pointer => |info| info.child,
                else => {
                    @compileLog(func);
                    unreachable;
                },
            };
            const func_info = @typeInfo(Func).Fn;
            const Result = func_info.return_type.?;
            const result_is_error_union = @typeInfo(Result) == .ErrorUnion;

            var args: std.meta.ArgsTuple(Func) = undefined;

            inline for (func_info.params, 0..) |arg, i| {
                const Arg = arg.type.?;

                if (comptime !is_injectable(Arg)) {
                    @compileError(@typeName(Arg) ++ " is not injectable");
                }

                comptime var found_provider = false;
                inline for (providers) |provider| {
                    if (Arg == provider.T) {
                        if (found_provider) @compileError("Multiple providers found for type: " ++ @typeName(Arg));
                        const provider_func: *const fn(data: Input) Error!Arg = @ptrCast(provider.provider);
                        args[i] = try provider_func(data);
                        found_provider = true;
                    }
                }

                if (!found_provider) {
                    @compileLog(providers);
                    @compileError("No provider found for type: " ++ @typeName(Arg));
                }
            }

            defer if (result_is_error_union) {
                inline for (args) |a| {
                    const Arg = @TypeOf(a);
                    inline for (providers) |provider| {
                        if (Arg == provider.T) {
                            if (provider.cleanup) |cleanup_func_opaque| {
                                const cleanup_func: *const fn(data: Arg) void = @ptrCast(cleanup_func_opaque);
                                cleanup_func(a);
                            }
                        }
                    }
                }
            };

            errdefer if (result_is_error_union) {
                inline for (args) |a| {
                    const Arg = @TypeOf(a);
                    inline for (providers) |provider| {
                        if (Arg == provider.T) {
                            if (provider.err_cleanup) |cleanup_func_opaque| {
                                const cleanup_func: *const fn(data: Arg) void = @ptrCast(cleanup_func_opaque);
                                cleanup_func(a);
                            }
                        }
                    }
                }
            };

            const result = if (result_is_error_union) (try @call(.auto, func, args)) else @call(.auto, func, args);

            switch (@typeInfo(Output)) {
                .Union => |output_info| {
                    if (output_info.tag_type) |_| {
                        switch (@typeInfo(@TypeOf(result))) {
                            .Union => |result_info| {
                                if (result_info.tag_type) |_| {
                                    inline for (output_info.fields) |output_field| {
                                        inline for (result_info.fields) |result_field| {
                                            if (output_field.type == result_field.type
                                                and std.mem.eql(u8, result_field.name, @tagName(result))
                                                and comptime std.mem.eql(u8, output_field.name, result_field.name)
                                            ) {
                                                return @unionInit(Output, output_field.name, @field(result, result_field.name));
                                            }
                                        }
                                    }
                                }
                            },
                            else => {},
                        }

                        inline for (output_info.fields) |field| {
                            if (@TypeOf(result) == field.type) {
                                return @unionInit(Output, field.name, result);
                            }
                        }
                        unreachable;
                    }
                },
                else => {},
            }
                        
            return result;
        }

        pub fn extend(comptime Provider_Decls: type) type {
            const combined_providers = parse_providers(Provider_Decls, Input, Error, providers);
            return Injector_Internal(combined_providers, Input, Output, Error);
        }
    };
}

fn parse_providers(comptime Provider_Decls: type, comptime Input: type, comptime Error: type, comptime parent_providers: []const Provider_Mapping) []const Provider_Mapping {
    return comptime res: {
        var providers = parent_providers;

        if (providers.len == 0 and is_injectable(Input)) {
            providers = providers ++ .{
                .{
                    .T = Input,
                    .provider = struct {
                        pub fn identity(data: Input) Error!Input {
                            return data;
                        }
                    }.identity,
                    .err_cleanup = null,
                    .cleanup = null,
                },
            };
        }

        for (std.meta.declarations(Provider_Decls)) |decl| {
            const name = decl.name;
            if (!std.mem.startsWith(u8, name, "inject_")) continue;
            if (std.mem.endsWith(u8, name, "_cleanup") and @hasDecl(Provider_Decls, name[0 .. name.len - "_cleanup".len])) continue;
            if (std.mem.endsWith(u8, name, "_cleanup_err") and @hasDecl(Provider_Decls, name[0 .. name.len - "_cleanup_err".len])) continue;
            providers = providers ++ .{ parse_provider(Provider_Decls, name, Input, Error, parent_providers) };
        }

        break :res providers;
    };
}

fn parse_provider(comptime Provider_Decls: type, comptime name: []const u8, comptime Input: type, comptime Error: type, comptime parent_providers: []const Provider_Mapping) Provider_Mapping {
    const Injected = Injected_Type(Provider_Decls, name);
    if (!is_injectable(Injected)) @compileError(@typeName(Provider_Decls) ++ "." ++ name ++ " provides a non-injectable type: " ++ @typeName(Injected));
    return .{
        .T = Injected,
        .provider = parse_provider_func(Provider_Decls, name, Injected, Input, Error, parent_providers),
        .cleanup = parse_cleanup_func(Provider_Decls, name ++ "_cleanup", Injected),
        .err_cleanup = parse_cleanup_func(Provider_Decls, name ++ "_cleanup_err", Injected),
    };
}

fn Injected_Type(comptime Provider_Decls: type, comptime name: []const u8) type {
    const Decl_Type = @TypeOf(@field(Provider_Decls, name));
    switch (@typeInfo(Decl_Type)) {
        .Fn => |info| {
            switch (@typeInfo(info.return_type.?)) {
                .ErrorUnion => |err_info| return err_info.payload,
                else => return info.return_type.?,
            }
        },
        else => return Decl_Type,
    }
}

fn parse_provider_func(comptime Provider_Decls: type, comptime name: []const u8, comptime Injected: type, comptime Input: type, comptime Error: type, comptime parent_providers: []const Provider_Mapping) *const fn(data: Input) Error!Injected {
    const Decl_Type = @TypeOf(@field(Provider_Decls, name));
    if (fn_signatures_exactly_eql(Decl_Type, fn(data: Input) Error!Injected)) {
        return @field(Provider_Decls, name);
    }

    if (@typeInfo(Decl_Type) != .Fn) {
        return struct {
            pub fn provider(_: Input) Error!Injected {
                return @field(Provider_Decls, name);
            }
        }.provider;
    }

    const fn_info = @typeInfo(Decl_Type).Fn;

    if (fn_info.params.len == 0) {
        if (@typeInfo(fn_info.return_type.?) == .ErrorUnion) {
            return struct {
                pub fn provider(_: Input) Error!Injected {
                    return try @field(Provider_Decls, name)();
                }
            }.provider;
        } else {
            return struct {
                pub fn provider(_: Input) Error!Injected {
                    return @field(Provider_Decls, name)();
                }
            }.provider;
        }
    }

    if (fn_info.params.len == 1 and fn_info.params[0].type == Input) {
        if (@typeInfo(fn_info.return_type.?) == .ErrorUnion) {
            return struct {
                pub fn provider(data: Input) Error!Injected {
                    return try @field(Provider_Decls, name)(data);
                }
            }.provider;
        } else {
            return struct {
                pub fn provider(data: Input) Error!Injected {
                    return @field(Provider_Decls, name)(data);
                }
            }.provider;
        }
    }

    if (parent_providers.len > 0) {
        return struct {
            pub fn provider(data: Input) Error!Injected {
                const Parent = Injector_Internal(parent_providers, Input, Injected, Error);
                return try Parent.call(@field(Provider_Decls, name), data);
            }
        }.provider;
    }

    @compileError(@typeName(Provider_Decls) + "." + name + " is not a valid injection provider");
}

fn parse_cleanup_func(comptime Provider_Decls: type, comptime name: []const u8, comptime Injected: type) ?*const fn(data: Injected) void {
    if (!@hasDecl(Provider_Decls, name)) return null;
    const ptr: *const fn(data: Injected) void = @field(Provider_Decls, name);
    return ptr;
}

fn is_injectable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Struct, .Union, .Enum, .Opaque => if (@hasDecl(T, "is_injectable")) T.is_injectable else true,
        .Pointer => |info| is_injectable(info.child),
        .Array => |info| is_injectable(info.child),
        .Optional => |info| is_injectable(info.child),
        else => false,
    };
}

fn fn_signatures_exactly_eql(comptime fn1: type, comptime fn2: type) bool {
    if (@typeInfo(fn1) != .Fn or @typeInfo(fn2) != .Fn) return false;
    const info1 = @typeInfo(fn1).Fn;
    const info2 = @typeInfo(fn2).Fn;
    if (!std.meta.eql(info1.params, info2.params)) return false;
    if (info1.return_type.? != info2.return_type.?) return false;
    if (info1.is_var_args != info2.is_var_args) return false;
    if (info1.is_generic != info2.is_generic) return false;
    if (info1.alignment != info2.alignment) return false;
    if (info1.calling_convention != info2.calling_convention) return false;
    return true;
}

const std = @import("std");
