--!nonstrict
-- An explicitly selected shell initializes toolchains in the command's directory. Captured variables are
-- private, in-memory child-process input: never plugin settings, UI, logs, or diagnostic attachments.
local ShellEnv = {}
local CACHE = {}
local REVISION = nil
local INIT_MS = 30 * 1000
local KINDS = { pwsh = true, bash = true, zsh = true }

function ShellEnv.config()
	local ok, value = pcall(tern.kv.get, "execution")
	return if ok and type(value) == "table" then value else { mode = "inherited", revision = 0 }
end

function ShellEnv.configure(kind: string?, shell: string?): (boolean, string?)
	if kind and (not KINDS[kind] or type(shell) ~= "string" or not string.match(shell, "^[/\\]") and not string.match(shell, "^%a:[/\\]")) then
		return false, "Choose an absolute path to PowerShell, Bash, or Zsh."
	end
	if kind then
		local ok, found = pcall(tern.fs.exists, shell)
		if not ok or not found then return false, "The selected shell executable does not exist." end
	end
	local before = ShellEnv.config()
	tern.kv.set("execution", { mode = if kind then "shell" else "inherited", kind = kind, shell = shell, revision = (tonumber(before.revision) or 0) + 1 })
	CACHE, REVISION = {}, nil
	return true, nil
end

function ShellEnv.refresh()
	local config = ShellEnv.config()
	tern.kv.set("execution", { mode = config.mode, kind = config.kind, shell = config.shell, revision = (tonumber(config.revision) or 0) + 1 })
	CACHE, REVISION = {}, nil
end

function ShellEnv.path(env): string
	if tern.runtime.os == "windows" then
		return tostring((env and (env.Path or env.PATH)) or tern.getenv("Path") or tern.getenv("PATH") or "")
	end
	return tostring((env and env.PATH) or tern.getenv("PATH") or "")
end

local function failure(code, message)
	return { code = code, message = message, details = {}, nextStep = "Choose Inherited environment in dev settings, or repair the selected shell's startup configuration and refresh its environment." }
end

local function unpack_env(stdout, kind)
	-- Interactive shells may echo commands and profiles may print arbitrary text. Raw RS/US delimiters
	-- are emitted by the capture command, not present in its source, and never displayed to the user.
	local first = string.find(stdout, string.char(30), 1, true)
	local last = nil
	if first then
		local at = first + 1
		while true do
			local pos = string.find(stdout, string.char(31), at, true)
			if not pos then break end
			last, at = pos, pos + 1
		end
	end
	if not first or not last then return nil end
	local payload = string.sub(stdout, first + 1, last - 1)
	local values = {}
	if kind == "pwsh" then
		local ok, decoded = pcall(tern.json.decode, payload)
		if not ok or type(decoded) ~= "table" then return nil end
		for key, value in decoded do
			if type(key) ~= "string" or type(value) ~= "string" then return nil end
			values[key] = value
		end
	else
		for _, entry in string.split(payload, string.char(0)) do
			local key, value = string.match(entry, "^([^=]+)=(.*)$")
			if key then values[key] = value end
		end
	end
	local out = {}
	for key, value in values do
		-- Tern's routing and pane identity belong to the caller, not the initialization shell.
		if string.sub(string.upper(key), 1, 5) ~= "TERN_" and not string.find(key, "[=%z]") then
			out[if tern.runtime.os == "windows" and string.upper(key) == "PATH" then "Path" else key] = value
		end
	end
	if out.Path == nil and out.PATH == nil then return nil end
	return out
end

local function command(config)
	if config.kind == "pwsh" then
		-- A real interactive prompt runs activation hooks (for example mise's directory-dependent PATH).
		-- -Command would load the profile but skip those hooks. No profile is run in inherited mode.
		return { config.shell, "-NoLogo", "-NoExit" }, "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); [Console]::Write([char]30); [Console]::Write((ConvertTo-Json -InputObject ([Environment]::GetEnvironmentVariables('Process')) -Compress)); [Console]::Write([char]31); exit\n"
	end
	local convert = if tern.runtime.os == "windows" then 'PATH="$(cygpath -wp "$PATH")" || exit 1; export PATH; ' else ""
	return { config.shell, "-il" }, convert .. "printf '\\036'; /usr/bin/env -0; printf '\\037'; exit\n"
end

function ShellEnv.resolve(cwd: string, done)
	local config = ShellEnv.config()
	if config.mode ~= "shell" then return done({}, nil, nil) end
	if not KINDS[config.kind] or type(config.shell) ~= "string" or config.shell == "" then
		return done(nil, failure("ENVIRONMENT", "The selected initialization shell is invalid."), nil)
	end
	local revision = tostring(config.revision or 0) .. ":" .. config.kind .. ":" .. config.shell
	if revision ~= REVISION then CACHE, REVISION = {}, revision end
	local key = if tern.runtime.os == "windows" then string.lower(string.gsub(cwd, "\\", "/")) else cwd
	local cached = CACHE[key]
	if cached then
		if cached.env then return done(cached.env, nil, nil) end
		table.insert(cached.waiters, done)
		return
	end
	local entry = { waiters = { done } }
	CACHE[key] = entry
	local argv, stdin = command(config)
	local function finish(env, err, cx)
		local current = ShellEnv.config()
		if REVISION ~= revision or current.mode ~= "shell" or current.kind ~= config.kind or current.shell ~= config.shell or current.revision ~= config.revision then
			env, err = nil, failure("ENV_CHANGED", "Execution settings changed while the shell was initializing. Run the operation again.")
		end
		if env then entry.env = env elseif CACHE[key] == entry then CACHE[key] = nil end
		local waiters = entry.waiters
		entry.waiters = nil
		for _, notify in waiters do notify(env, err, cx) end
	end
	local ok = pcall(tern.process.run, argv, { cwd = cwd, stdin = stdin, timeout_ms = INIT_MS }, function(result, cx)
		if result.timed_out then return finish(nil, failure("ENV_TIMEOUT", "The selected shell did not finish initialization within 30 seconds; it was stopped."), cx) end
		if result.status ~= 0 then return finish(nil, failure("ENVIRONMENT", "The selected shell failed to initialize. Its output is withheld because profiles can print secrets."), cx) end
		local env = unpack_env(result.stdout, config.kind)
		if not env then return finish(nil, failure("ENVIRONMENT", "The selected shell did not return an exported PATH. Its output is withheld because profiles can print secrets."), cx) end
		finish(env, nil, cx)
	end)
	if not ok then finish(nil, failure("ENVIRONMENT", "Tern could not start the selected initialization shell."), nil) end
end

-- ProcessOptions.env only overlays the caller. A profile may deliberately remove a variable, so
-- opt-in commands install the captured snapshot in an unprofiled shell before starting the child.
-- The snapshot travels through stdin, never argv, disk, UI or logs. Tern routing stays caller-owned.
local POWERSHELL_EXEC = [=[
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$payload = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd())
$start = [System.Diagnostics.ProcessStartInfo]::new()
# Windows PowerShell uses EnvironmentVariables; PowerShell 7 exposes the native dictionary.
$environment = $start.EnvironmentVariables
if ($start.PSObject.Properties['Environment']) { $environment = $start.Environment }
$environment.Clear()
foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
    if ($name.StartsWith('TERN_', [StringComparison]::OrdinalIgnoreCase)) {
        $environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
}
foreach ($entry in $payload.env.PSObject.Properties) { $environment[$entry.Name] = [string]$entry.Value }
$program = [string]$payload.argv[0]
if (-not [System.IO.Path]::IsPathRooted($program)) {
    if ($program.Contains('/') -or $program.Contains('\')) {
        $program = [System.IO.Path]::GetFullPath($program)
    } else {
        $found = $null
        $searchPath = $environment['PATH']
        if ($null -eq $searchPath) { $searchPath = $environment['Path'] }
        foreach ($directory in ([string]$searchPath).Split([System.IO.Path]::PathSeparator)) {
            if (-not $directory) { continue }
            foreach ($name in @($program, "$program.exe")) {
                $candidate = [System.IO.Path]::Combine($directory.Trim('"'), $name)
                if ([System.IO.File]::Exists($candidate)) { $found = [System.IO.Path]::GetFullPath($candidate); break }
            }
            if ($found) { break }
        }
        if (-not $found) { throw 'The selected environment could not locate the requested executable.' }
        $program = $found
    }
}
$start.FileName = $program
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WorkingDirectory = [Environment]::CurrentDirectory
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
if ($start.PSObject.Properties['ArgumentList']) {
    for ($i = 1; $i -lt $payload.argv.Count; $i++) { $start.ArgumentList.Add([string]$payload.argv[$i]) }
} else {
    # Windows PowerShell's .NET Framework needs Windows command-line quoting.
    $arguments = for ($i = 1; $i -lt $payload.argv.Count; $i++) {
        $value = [regex]::Replace([string]$payload.argv[$i], '(\\*)"', '$1$1\"')
        '"' + [regex]::Replace($value, '(\\+)$', '$1$1') + '"'
    }
    $start.Arguments = $arguments -join ' '
}
# Attach the launcher before spawning: assigning an already-running child leaves a race.
# Only this process owns the non-inherited handle, so SDK timeout closes it and kills the tree.
$windowsJob = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($windowsJob) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class TernChildJob {
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits {
        public BasicLimits BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimits information, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    private static IntPtr job;
    private static void KillOnClose(bool enabled) {
        var limits = new ExtendedLimits();
        limits.BasicLimitInformation.LimitFlags = enabled ? 0x2000u : 0u;
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot protect command process lifetime.");
    }
    public static void Attach() {
        job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot create command process lifetime.");
        try {
            KillOnClose(true);
            if (!AssignProcessToJobObject(job, GetCurrentProcess()))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot protect command process lifetime.");
        } catch {
            CloseHandle(job);
            job = IntPtr.Zero;
            throw;
        }
    }
    public static void Complete() {
        // A returned command may intentionally leave background work. Only abnormal exit kills it.
        KillOnClose(false);
        CloseHandle(job);
        job = IntPtr.Zero;
    }
}
'@
    [TernChildJob]::Attach()
}
$child = [System.Diagnostics.Process]::Start($start)
$child.StandardInput.Close()
$output = $child.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())
$errors = $child.StandardError.BaseStream.CopyToAsync([Console]::OpenStandardError())
$child.WaitForExit()
[System.Threading.Tasks.Task]::WaitAll(@($output, $errors))
if ($windowsJob) { [TernChildJob]::Complete() }
exit $child.ExitCode
]=]

function ShellEnv.run(argv, options, done)
	local config = ShellEnv.config()
	if config.mode ~= "shell" then return tern.process.run(argv, options, done) end
	local launch = table.clone(options)
	launch.env = { BASH_ENV = "", ENV = "" }
	if tern.runtime.os == "windows" or config.kind == "pwsh" then
		-- Bash cannot set Windows environment names such as ProgramFiles(x86).
		-- Use the OS-supplied, unprofiled launcher after any Windows shell capture.
		local shell = if config.kind == "pwsh" then config.shell else (tern.getenv("SystemRoot") or tern.getenv("WINDIR") or "") .. "/System32/WindowsPowerShell/v1.0/powershell.exe"
		launch.stdin = tern.json.encode({ argv = argv, env = options.env or {} })
		return tern.process.run({ shell, "-NoProfile", "-NoLogo", "-NonInteractive", "-Command", POWERSHELL_EXEC }, launch, done)
	end
	local unexport = if config.kind == "bash" then "export -n" else "typeset +x"
	local script = [=[
while IFS= read -r -d '' item; do
    name="${item%%=*}"
    case "$name" in TERN_*) ;; *) UNEXPORT "$name" || exit 125 ;; esac
done < <(/usr/bin/env -0)
IFS= read -r count || exit 125
for ((i=0; i<count; i++)); do
    IFS= read -r -d '' item || exit 125
    export "$item" || exit 125
done
IFS= read -r count || exit 125
command_args=()
for ((i=0; i<count; i++)); do
    IFS= read -r -d '' item || exit 125
    command_args+=("$item")
done
exec "${command_args[@]}"
]=]
	script = string.gsub(script, "UNEXPORT", unexport)
	local entries = {}
	for name, value in options.env or {} do table.insert(entries, name .. "=" .. value) end
	launch.stdin = tostring(#entries) .. "\n" .. table.concat(entries, "\0") .. (if #entries > 0 then "\0" else "")
		.. tostring(#argv) .. "\n" .. table.concat(argv, "\0") .. "\0"
	local args = if config.kind == "bash" then { config.shell, "--noprofile", "--norc", "-c", script } else { config.shell, "-f", "-c", script }
	return tern.process.run(args, launch, done)
end

return ShellEnv
