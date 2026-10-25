# Plan: an ARM64 build of NppMenuSearch

Branch `arm64`, started 25/10/2026 from `master` (upstream `c4fde81` plus the `TabItem` view-name fix).

## Goal

Make NppMenuSearch load in the native ARM64 build of Notepad++, with as little change to the project as possible. The ideal is a change small enough for Peter to accept upstream: no new target framework, no new runtime for users to install, and no rewrite of the WinForms UI.

## Background

- Notepad++ ships native ARM64 builds, with its own plugin list (`pl.arm64.json`). NppMenuSearch isn't on that list.
- An ARM64 process can't load an x64 DLL. Today, ARM64 users have to run the x64 Notepad++ under emulation to use this plugin.
- The plugin is a .NET Framework DLL. `UnmanagedExports` (RGiesecke, 2015) gives it native exports (`isUnicode`, `setInfo`, `getFuncsArray`, `messageProc`, `getName`, `beNotified`). It does this by disassembling the compiled DLL with `ildasm`, adding `.vtfixup` and `.export` directives, then reassembling it with `ilasm /X64`. The tool officially supports only x86 and x64.
- **Key finding (25/10/2026):** the .NET Framework 4.8 `ilasm.exe` has an `/ARM64` switch. The IL for x64 and ARM64 is identical, because both are 64-bit and the code only uses `IntPtr`. So the x64 build's IL can be reassembled as an ARM64 image, including its export table. Doing that here produced a DLL with machine type `AA64`, all 6 exports and all 4 embedded resources.
- .NET Framework 4.8.1 added native ARM64 support on Windows 11, and Windows 11 ARM64 includes it. So if this works, users need nothing extra installed.
- **The open question is whether the ARM64 CLR in .NET Framework 4.8.1 supports unmanaged exports (`.vtfixup ... fromunmanaged`).** Microsoft doesn't document this either way. C++/CLI relies on similar machinery, and as far as I know it isn't supported on ARM64 for .NET Framework, so it may fail. Only a test on real ARM64 hardware can answer it. Phase 1 is that test.

## Phase 0: check the ARM64 machine

Run these in PowerShell on the ARM64 machine:

| Check | Command | Expected |
|---|---|---|
| Windows 11 on ARM64 | `(Get-CimInstance Win32_OperatingSystem).Caption; $env:PROCESSOR_ARCHITECTURE` | Windows 11, `ARM64` |
| .NET Framework 4.8.1 | `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release` | 533320 or higher |
| Native ARM64 CLR present | `Test-Path $env:windir\Microsoft.NET\FrameworkArm64\v4.0.30319\clr.dll` | `True` |
| ARM64 Notepad++ | Notepad++ → `?` → About. Or install it from the `.arm64` installer or portable zip on the Notepad++ downloads page | About says "ARM 64-bit" |

If you're building on the ARM64 machine itself, you also need Visual Studio 2022 with the .NET desktop workload, which provides MSBuild and `ildasm`. The project targets .NET 4.0, so that machine also needs the 4.0 reference assemblies, just like the x64 laptop did. Alternatively, build on the x64 laptop and copy `NppMenuSearch\bin\ARM64\Release\` across.

## Phase 1: spike, reassemble the x64 IL as ARM64 (this branch)

`arm64\Build-Arm64.ps1` does the following:

1. Builds Release|x64 as normal.
2. Runs `ildasm` on the result.
3. Runs `ilasm /DLL /ARM64 /PE64`.
4. Checks that the result's PE machine type is `0xAA64`.
5. Writes the DLL and the language files to `NppMenuSearch\bin\ARM64\Release\`.

- `Build-Arm64.cmd`: build only.
- `Build-And-Install-Arm64.cmd`: build, then install into `C:\Program Files\Notepad++\plugins\NppMenuSearch\`. Run it as administrator. It renames a locked DLL to `.old`, so Notepad++ can stay open. Restart Notepad++ afterwards.
- `-NoBuild` reuses an existing x64 build. `-NppDir` installs into a portable Notepad++.

### Test checklist (ARM64 Notepad++)

1. Notepad++ starts with no "failed to load plugin" message, and Plugins → NppMenuSearch exists.
2. The search box appears in the toolbar. Ctrl+F1 (Plugins → NppMenuSearch → Menu Search...) focuses it.
3. Typing `find` lists menu items and Preferences entries. Enter runs the selected item.
4. Open a few files and type part of a name. The "Open Files" group appears, and clicking one switches to that tab.
5. Right-click a result to get the context menu. Hovering an open file shows a tooltip after right-clicking the list. Always-show tooltips are on a separate branch.
6. Switch dark mode on and off in Preferences, and check that the popup follows.
7. Switch the Notepad++ language to German, and check that the plugin's strings change.
8. Close Notepad++ and check there's no crash on exit.
9. Confirm it really runs natively: in Process Explorer (or `tasklist /m clr.dll`), `notepad++.exe` should have `clr.dll` loaded from `FrameworkArm64`.

### If it fails, collect

- The exact text of any Notepad++ error message.
- Event Viewer → Windows Logs → Application: any ".NET Runtime" or "Application Error" entries for `notepad++.exe`, including the exception code and faulting module.
- Whether `clr.dll` was loaded at all (Process Explorer → notepad++.exe → DLLs).

Interpreting the result:
- **"Failed to load" with no `clr.dll` loaded:** the Windows loader or `mscoree` rejected the image.
- **`clr.dll` loaded, then a crash or an error from the first export call:** the ARM64 CLR doesn't support unmanaged export thunks. Go to Phase 3.

## Phase 2: if the spike works, make it a proper build

1. Move the ildasm/ilasm step from the script into MSBuild: an `ARM64` solution platform, plus an AfterBuild target that runs `ilasm /ARM64` on UnmanagedExports' output. This could reuse the IL file UnmanagedExports already writes, if its task can be told to keep it. Otherwise use ildasm as the script does.
2. Add the ARM64 build to CI and the release zip, either with AppVeyor (the image needs the 4.8 SDK tools) or a GitHub Actions `windows-2022` job.
3. Test x86 and x64 again, since their builds must not change.
4. Offer it upstream as a small PR: one build step, no framework change, nothing for users to install on Windows 11 ARM64.
5. Ask for NppMenuSearch to be added to `pl.arm64.json` in `notepad-plus-plus/nppPluginList`. This is normally done by Peter or with his agreement.

## Phase 3: fallback, a native ARM64 shim that hosts .NET Framework

Use this if the ARM64 CLR can't run unmanaged exports. It still keeps .NET Framework and the WinForms code as they are:

- A small C++ DLL named `NppMenuSearch.dll`, built for ARM64 (and optionally x86/x64), exports the 6 plugin functions.
- On the first call (never in `DllMain`), it loads `mscoree.dll`, calls `CLRCreateInstance` → `ICLRMetaHost::GetRuntime(L"v4.0.30319")` → `ICLRRuntimeHost::Start`. Then it calls `ExecuteInDefaultAppDomain` on a static `int Init(string)` method in the managed DLL.
- `Init` receives the address of a native function-pointer table as a string, and fills it with `Marshal.GetFunctionPointerForDelegate` of rooted static delegates. After that, each export forwards straight to the managed code.
- The managed assembly is renamed (for example `NppMenuSearch.Core.dll`) and built AnyCPU. `Localizations.OpenPluginLocalization` must then look for `NppMenuSearch.dll.<lang>.xml` by plugin name rather than by `Assembly.Location`. Peter's `wrapper-dll` branch already makes that change.
- Needs the Visual Studio component "MSVC v143 – VS 2022 C++ ARM64/ARM64EC build tools", which isn't installed on the x64 laptop yet. The NETFX SDK has no ARM64 `mscoree.lib`, so load `mscoree.dll` dynamically with `LoadLibrary`/`GetProcAddress`.
- This is close to Peter's own `wrapper-dll` idea (#60), but it uses the CLR hosting API instead of C++/CLI. As far as I know, C++/CLI can't target ARM64 for .NET Framework.

## Phase 4: last resort, modern .NET with DNNE

- Convert to an SDK-style `net8.0-windows` (or later) WinForms project, mark the exports `[UnmanagedCallersOnly]`, and let DNNE generate the native ARM64 export DLL.
- Costs:
  - Users must install the .NET Desktop Runtime (ARM64).
  - Two DLLs.
  - Notepad++'s types must be written as C declarations for DNNE.
  - The old WinForms `ContextMenu`/`MenuItem` don't exist in .NET Core 3.1 and later, so `ResultsPopup` and `ToolbarSearchForm` would need `ContextMenuStrip`.
  - Only one modern .NET runtime can load per process, so this could clash with other .NET plugins.
- Native AOT isn't an option, because WinForms doesn't support it.

## Status

| Date | Step | Result |
|---|---|---|
| 25/10/2026 | Phase 1 build on x64 laptop | ARM64 DLL produced: machine `AA64`, 6 exports, 4 resources, 161,792 bytes. **Not yet run on ARM64.** |
