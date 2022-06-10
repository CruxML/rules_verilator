"""Rules for compiling Verilog files to C++ using Verilator"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_LINK_STATIC_LIBRARY_ACTION_NAME",
)

def _link_static_library(
        owner,
        name,
        actions,
        feature_configuration,
        compilation_outputs,
        cc_toolchain,
        user_link_flags = None,
        linking_contexts = []):
    """Link object files into a static library"""
    static_library = actions.declare_file("lib{name}.a".format(name = name))
    link_tool = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
    )
    link_variables = cc_common.create_link_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        output_file = static_library.path,
        is_using_linker = False,  # False for static library
        is_linking_dynamic_library = False,  # False for static library
        user_link_flags = user_link_flags,
    )
    link_env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
        variables = link_variables,
    )
    link_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
        variables = link_variables,
    )

    # Dependency libraries to link.
    # TODO: Not clear how to remove to_list here, see
    # https://github.com/bazelbuild/bazel/issues/8118#issuecomment-487175926
    dep_objects = []
    for context in linking_contexts:
        for linker_input in context.linker_inputs.to_list():
            for lib in linker_input.libraries:
                dep_objects += lib.objects

    # Run linker
    args = actions.args()
    args.add_all(link_flags)
    args.add_all(compilation_outputs.objects)
    args.add_all(dep_objects)
    actions.run(
        outputs = [static_library],
        inputs = depset(
            direct = compilation_outputs.objects + dep_objects,
            transitive = [cc_toolchain.all_files],
        ),
        executable = link_tool,
        arguments = [args],
        mnemonic = "StaticLink",
        progress_message = "Linking {}".format(static_library.short_path),
        env = link_env,
    )

    # Build the linking info provider
    linker_input = cc_common.create_linker_input(
        owner = owner,
        libraries = depset(direct = [
            cc_common.create_library_to_link(
                actions = actions,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
                static_library = static_library,
            ),
        ]),
        user_link_flags = user_link_flags,
    )
    linking_context = cc_common.create_linking_context(
        linker_inputs = depset(direct = [linker_input]),
    )

    # Merge linking info for downstream rules
    linking_contexts.append(linking_context)
    cc_infos = [CcInfo(linking_context = linking_context) for linking_context in linking_contexts]
    merged_cc_info = cc_common.merge_cc_infos(
        cc_infos = cc_infos,
    )

    # Workaround to emulate CcLinkingInfo (the return value of cc_common.link)
    return struct(
        linking_context = merged_cc_info.linking_context,
        cc_linking_outputs = struct(
            static_libraries = [static_library],
        ),
    )

def cc_compile_and_link_static_library(
        ctx,
        srcs,
        hdrs,
        deps,
        includes = [],
        defines = [],
        runfiles = None):
    """Compile and link C++ source into a static library"""
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    compilation_contexts = [dep[CcInfo].compilation_context for dep in deps]
    compilation_context, compilation_outputs = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = srcs,
        includes = includes,
        defines = defines,
        public_hdrs = hdrs,
        compilation_contexts = compilation_contexts,
    )

    linking_contexts = [dep[CcInfo].linking_context for dep in deps]
    linking_info = _link_static_library(
        owner = ctx.label,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        linking_contexts = linking_contexts,
        name = ctx.label.name,
    )

    static_depset = depset(linking_info.cc_linking_outputs.static_libraries)
    return [
        DefaultInfo(
            files = static_depset,
            runfiles = runfiles,
        ),
        CcInfo(
            compilation_context = compilation_context,
            linking_context = linking_info.linking_context,
        ),
    ]
