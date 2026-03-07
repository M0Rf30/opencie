; SPDX-FileCopyrightText: 2026 Gianluca Boiano
; SPDX-License-Identifier: GPL-2.0-or-later
;
; Inno Setup script for OpenCIE — the open-source Italian Electronic
; Identity Card (CIE) application.
;
; Build:
;   iscc installer\opencie.iss
;
; Prerequisites (in build\windows\x64\runner\Release\):
;   - opencie.exe            (Flutter desktop app)
;   - opencie-pkcs11.dll     (CIE PKCS#11 module, renamed from libopencie-pkcs11.dll)
;   - flutter_windows.dll    (Flutter engine)
;   - data\                  (Flutter assets + AOT snapshot)
;   - Runtime dependency DLLs (OpenSSL, libcurl, MinGW runtime, etc.)

#define MyAppName      "OpenCIE"
#define MyAppVersion   "0.1.0"
#define MyAppPublisher "Gianluca Boiano"
#define MyAppURL       "https://github.com/M0Rf30/opencie"
#define MyAppExeName   "opencie.exe"
#define MyAppId        "io.github.m0rf30.opencie"

; Path to the Flutter release build output (relative to this .iss file).
#define BuildDir       "..\build\windows\x64\runner\Release"
#define AssetsDir      "assets"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; No code signing (unsigned installer).
OutputDir=..\build\installer
OutputBaseFilename=opencie-{#MyAppVersion}-windows-x86_64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes

; ── Wizard appearance ────────────────────────────────────────────────────────
WizardStyle=modern
; Left side panel (164×314) and top-right banner (55×55) — OpenCIE branding
WizardImageFile={#AssetsDir}\wizard_image.bmp
WizardSmallImageFile={#AssetsDir}\wizard_small_image.bmp

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
MinVersion=10.0
InfoBeforeFile=..\LICENSE.md

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "firefoxpkcs11"; Description: "Register CIE smart card module with Firefox"; GroupDescription: "Browser integration:"

[Files]
; --- Core application ---
Source: "{#BuildDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

; --- Flutter engine & runtime ---
Source: "{#BuildDir}\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion

; --- Flutter data (assets + AOT snapshot) ---
Source: "{#BuildDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

; --- CIE PKCS#11 module (renamed from libopencie-pkcs11.dll by CMake) ---
Source: "{#BuildDir}\opencie-pkcs11.dll"; DestDir: "{app}"; Flags: ignoreversion

; --- All other DLLs (plugins, runtime deps) ---
Source: "{#BuildDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion; Excludes: "opencie-pkcs11.dll,flutter_windows.dll"

[Registry]
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; Check: NeedsAddPath(ExpandConstant('{app}')); Flags: preservestringtype

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Clean up any Firefox pkcs11.txt modifications or cached data.
Type: filesandordirs; Name: "{app}\data"

[Code]
// ---------------------------------------------------------------------------
// Firefox PKCS#11 module registration
//
// Firefox discovers PKCS#11 modules via a "pkcs11.txt" file in each profile
// directory.  We parse %APPDATA%\Mozilla\Firefox\profiles.ini to find all
// profile directories, then append a "library=" / "name=" block to each
// profile's pkcs11.txt.  This follows the same approach as OpenSC's
// pkcs11-register tool.
//
// Note: Chrome on Windows does NOT use PKCS#11 modules — it relies on
// Windows CNG / Smart Card Minidriver instead.  No Chrome registration
// is needed or possible with a PKCS#11-only DLL.
//
// On uninstall we remove the lines we added.
// ---------------------------------------------------------------------------

function NeedsAddPath(Param: string): boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKEY_LOCAL_MACHINE,
    'SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
    'Path', OrigPath)
  then begin
    Result := True;
    exit;
  end;
  Result := Pos(';' + Param + ';', ';' + OrigPath + ';') = 0;
end;

const
  PKCS11_MODULE_NAME = 'OpenCIE PKCS#11';
  PKCS11_DLL_NAME    = 'opencie-pkcs11.dll';

/// Register the PKCS#11 module in a single Firefox profile directory.
procedure RegisterPkcs11InProfile(const ProfileDir, DllPath: String);
var
  Pkcs11File: String;
  Lines: TArrayOfString;
  i: Integer;
  Found: Boolean;
begin
  if not DirExists(ProfileDir) then
    Exit;

  Pkcs11File := ProfileDir + '\pkcs11.txt';

  // Check if already registered.
  Found := False;
  if FileExists(Pkcs11File) then
  begin
    if LoadStringsFromFile(Pkcs11File, Lines) then
    begin
      for i := 0 to GetArrayLength(Lines) - 1 do
      begin
        if Pos(PKCS11_DLL_NAME, Lines[i]) <> 0 then
        begin
          Found := True;
          Break;
        end;
      end;
    end;
  end;

  if Found then
    Exit;

  // Append our module entry.  Firefox pkcs11.txt format (NSS 3.35+):
  //   library=<full-path-to-dll>
  //   name=<display-name>
  //   (blank line separator)
  SetArrayLength(Lines, 3);
  Lines[0] := 'library=' + DllPath;
  Lines[1] := 'name=' + PKCS11_MODULE_NAME;
  Lines[2] := '';
  SaveStringsToFile(Pkcs11File, Lines, True);
end;

/// Unregister the PKCS#11 module from a single Firefox profile directory.
procedure UnregisterPkcs11FromProfile(const ProfileDir, DllPath: String);
var
  Pkcs11File: String;
  Lines, NewLines: TArrayOfString;
  i, OutIdx: Integer;
  Skip: Boolean;
begin
  Pkcs11File := ProfileDir + '\pkcs11.txt';
  if not FileExists(Pkcs11File) then
    Exit;

  if not LoadStringsFromFile(Pkcs11File, Lines) then
    Exit;

  // Rebuild the file, dropping our library= and name= lines.
  SetArrayLength(NewLines, GetArrayLength(Lines));
  OutIdx := 0;
  Skip := False;

  for i := 0 to GetArrayLength(Lines) - 1 do
  begin
    if Lines[i] = 'library=' + DllPath then
      // Start skipping this module block (library + name + blank line).
      Skip := True
    else if Skip and ((Lines[i] = 'name=' + PKCS11_MODULE_NAME) or (Lines[i] = '')) then
      // Still inside our block — skip name= line and trailing blank.
    else
    begin
      Skip := False;
      NewLines[OutIdx] := Lines[i];
      OutIdx := OutIdx + 1;
    end;
  end;

  // Only rewrite if we actually removed something.
  if OutIdx < GetArrayLength(Lines) then
  begin
    SetArrayLength(NewLines, OutIdx);
    // Rewrite the file (overwrite = not append, so delete first).
    DeleteFile(Pkcs11File);
    SaveStringsToFile(Pkcs11File, NewLines, False);
  end;
end;

/// Parse profiles.ini and call Action for each profile directory found.
/// This is the proper way to discover Firefox profiles (matching OpenSC's
/// pkcs11-register.c approach).
procedure ForEachFirefoxProfile(IsRegister: Boolean);
var
  AppData, FirefoxDir, ProfilesIni, DllPath: String;
  Lines: TArrayOfString;
  i: Integer;
  ProfilePath, ProfileDir: String;
  IsRelative: Boolean;
begin
  AppData := ExpandConstant('{userappdata}');
  FirefoxDir := AppData + '\Mozilla\Firefox';
  ProfilesIni := FirefoxDir + '\profiles.ini';

  if not FileExists(ProfilesIni) then
    Exit;  // Firefox not installed for this user.

  if not LoadStringsFromFile(ProfilesIni, Lines) then
    Exit;

  DllPath := ExpandConstant('{app}\') + PKCS11_DLL_NAME;
  ProfilePath := '';
  IsRelative := True;

  for i := 0 to GetArrayLength(Lines) - 1 do
  begin
    // New section header — process the previous profile (if any).
    if (Length(Lines[i]) > 0) and (Lines[i][1] = '[') then
    begin
      if ProfilePath <> '' then
      begin
        if IsRelative then
          ProfileDir := FirefoxDir + '\' + ProfilePath
        else
          ProfileDir := ProfilePath;

        if IsRegister then
          RegisterPkcs11InProfile(ProfileDir, DllPath)
        else
          UnregisterPkcs11FromProfile(ProfileDir, DllPath);
      end;
      // Reset for the new section.
      ProfilePath := '';
      IsRelative := True;
    end
    else if Copy(Lines[i], 1, 11) = 'IsRelative=' then
      IsRelative := (Copy(Lines[i], 12, 1) = '1')
    else if Copy(Lines[i], 1, 5) = 'Path=' then
      ProfilePath := Copy(Lines[i], 6, Length(Lines[i]) - 5);
  end;

  // Don't forget the last profile in the file.
  if ProfilePath <> '' then
  begin
    if IsRelative then
      ProfileDir := FirefoxDir + '\' + ProfilePath
    else
      ProfileDir := ProfilePath;

    if IsRegister then
      RegisterPkcs11InProfile(ProfileDir, DllPath)
    else
      UnregisterPkcs11FromProfile(ProfileDir, DllPath);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if WizardIsTaskSelected('firefoxpkcs11') then
      ForEachFirefoxProfile(True);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    ForEachFirefoxProfile(False);
end;
