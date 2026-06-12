namespace TacticalRadio.Launcher;

public static class LauncherPaths
{
    public static string ResolveAppDir(string[] args)
    {
        var fromArgs = GetCommandLineAppDir(args);
        if (!string.IsNullOrWhiteSpace(fromArgs))
        {
            return Path.GetFullPath(fromArgs);
        }

        var fromEnvironment = Environment.GetEnvironmentVariable("TRADIO_APP_DIR");
        if (!string.IsNullOrWhiteSpace(fromEnvironment))
        {
            return Path.GetFullPath(fromEnvironment);
        }

        return AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    private static string? GetCommandLineAppDir(string[] args)
    {
        for (var index = 0; index < args.Length; index++)
        {
            var arg = args[index];

            if (arg.Equals("--app-dir", StringComparison.OrdinalIgnoreCase) && index + 1 < args.Length)
            {
                return args[index + 1];
            }

            const string prefix = "--app-dir=";
            if (arg.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return arg[prefix.Length..].Trim('"');
            }
        }

        return null;
    }
}
