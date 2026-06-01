# Tactical Radio Software

Tactical Radio Software connects Roblox player state to Mumble positional voice and tactical radio simulation.

The system has three main parts:

```text
Roblox game
  -> Bridge server
  -> Mumble plugin
  -> Mumble audio behavior
```

## Components

```text
bridge-server/
  Receives player position/radio state from Roblox.
  Exposes a local snapshot API for the Mumble plugin.

plugin/
  Mumble plugin that reads the bridge snapshot.
  Applies positional audio and radio behavior.

installer/
  Builds a Windows installer for the plugin and required DLLs.
```

---

# Building the Mumble Plugin

## Requirements

Install:

* Visual Studio 2022
* CMake
* Qt, if required by the current plugin build setup
* OpenSSL runtime DLLs:

  * `libcrypto-3-x64.dll`
  * `libssl-3-x64.dll`

## Configure Plugin Build

From the repository root:

```powershell
cmake -S apps/mumble-plugin `
  -B apps/mumble-plugin/build `
  -G "Visual Studio 17 2022" `
  -A x64 `
  -DCMAKE_TOOLCHAIN_FILE="C:\Users\manfr\Documents\Github\vcpkg\scripts\buildsystems\vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows

## Build

From the repository root:

```powershell
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

The compiled plugin should be produced as:

```text
release/tactical_radio_mumble_plugin.dll
```

The release folder should also contain:

```text
release/libcrypto-3-x64.dll
release/libssl-3-x64.dll
```

## Manual Plugin Install

Copy the plugin DLL into the Mumble plugin directory:

```text
%APPDATA%\Mumble\Mumble\Plugins
```

Only the plugin DLL belongs in the plugin folder:

```text
tactical_radio_mumble_plugin.dll
```

The OpenSSL DLLs should be placed beside `mumble.exe`, not inside the plugin folder:

```text
libcrypto-3-x64.dll
libssl-3-x64.dll
```

Restart Mumble after installing.

---

# Building the Installer

## Requirements

Install Inno Setup:

```powershell
winget install -e --id JRSoftware.InnoSetup
```

Make sure `ISCC.exe` is available in one of these locations:

```text
C:\Program Files (x86)\Inno Setup 6\ISCC.exe
C:\Program Files\Inno Setup 6\ISCC.exe
```

## Build Installer

From the repository root:

```powershell
.\build-installer.ps1
```

The script packages:

```text
release/tactical_radio_mumble_plugin.dll
release/libcrypto-3-x64.dll
release/libssl-3-x64.dll
```

The installer output should appear in the configured output folder, usually something like:

```text
installer-output/
```

## Installer Behavior

The installer should:

1. Install the Mumble plugin DLL into the Mumble plugin directory.
2. Install OpenSSL runtime DLLs beside `mumble.exe`.
3. Optionally unblock installed files.
4. Provide a clean uninstall path.

---

# Starting the Bridge Server

The bridge server is responsible for storing the latest Roblox player snapshot.

It should track:

```text
player username
player position
player orientation
alive/valid state
radio channels
radio PTT state
radio listening state
radio volume
radio ear assignment
```

## Start Server

From the bridge server directory:

```powershell
cd bridge-server
npm install
npm start
```

Or, if the server is written in another runtime, use the project-specific command, for example:

```powershell
python server.py
```

or:

```powershell
dotnet run
```

## Expected Local Endpoint

The Mumble plugin expects the bridge server to expose a local snapshot endpoint such as:

```text
http://127.0.0.1:3000/snapshot
```

Example snapshot:

```json
{
  "players": [
    {
      "username": "PlayerA",
      "position": [100.0, 3.0, 50.0],
      "forward": [0.0, 0.0, -1.0],
      "alive": true,
      "radios": [
        {
          "id": 1,
          "channel": "SQUAD",
          "listening": true,
          "transmitting": false,
          "ear": "left",
          "volume": 1.0,
          "minDistance": 0.0,
          "maxDistance": 3000.0
        }
      ]
    }
  ]
}
```

## Test Bridge Server

Open the snapshot endpoint in a browser:

```text
http://127.0.0.1:3000/snapshot
```

You should see valid JSON containing the current Roblox players.

---

# Basic Test Checklist

## 1. Bridge Server

```text
Bridge server starts without errors.
Snapshot endpoint returns JSON.
Roblox players appear in the snapshot.
Positions update while players move.
```

## 2. Mumble Plugin

```text
Mumble starts without plugin load errors.
Plugin appears in Mumble plugin settings.
Plugin logs successful bridge connection.
Plugin logs local player position.
Plugin logs other Roblox players.
```

## 3. Positional Voice

```text
Two players join the same Mumble channel.
Both players appear in the bridge snapshot.
Nearby players hear each other.
Far players are quieter or muted depending on range settings.
Left/right positional audio works correctly.
```

## 4. Installer

```text
Installer runs successfully.
Plugin DLL is installed into the Mumble plugin folder.
OpenSSL DLLs are installed beside mumble.exe.
Mumble starts without missing DLL errors.
Plugin loads successfully.
```

---

# Troubleshooting

## Plugin does not appear in Mumble

Check that the plugin DLL is in:

```text
%APPDATA%\Mumble\Mumble\Plugins
```

Restart Mumble.

## Mumble says DLL dependency is missing

Make sure these files are beside `mumble.exe`:

```text
libcrypto-3-x64.dll
libssl-3-x64.dll
```

Do not place them only inside the plugin folder.

## Plugin cannot connect to bridge server

Check that the bridge server is running and that this URL works:

```text
http://127.0.0.1:3000/snapshot
```

## Browser or Windows warns about the installer

Unsigned installers and EXE files may trigger warnings.

For public releases, use:

```text
code signing certificate
stable installer filename
HTTPS download
reputation building over time
clear versioning
```

---

# Development Notes

The current recommended architecture is:

```text
Bridge snapshot = source of truth
Mumble plugin = audio renderer
Mumble server = voice transport
Roblox = gameplay authority
```

Radio state should be controlled by Roblox, mirrored through the bridge server, and consumed by the Mumble plugin.
