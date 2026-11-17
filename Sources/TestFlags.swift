/// Flags for testing, compiled only into builds made with `make` or `make install`. A release build ignores them, so
/// no other process can start a listen through Muskey's System Audio Recording permission and save it to a file.
enum TestFlags {
    #if MUSKEY_DEV
        static func has(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

        static func value(_ name: String) -> String? {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
    #else
        static func has(_: String) -> Bool { false }
        static func value(_: String) -> String? { nil }
    #endif
}
