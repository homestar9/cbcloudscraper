# PyInstaller build definition for the cbcloudscraper worker.
#
# Do not run PyInstaller against this file by hand. Use build/build-binary.ps1, which
# sets the virtual environment, the work path, and the dist path consistently.
#
# The build is "onedir": it produces a folder (cbcloudscraper.exe next to an _internal
# folder of support files) rather than a single self-unpacking file. onedir starts fast
# on every run, which matters because the ColdBox module launches this program once per
# HTTP request.
import os

from PyInstaller.utils.hooks import collect_all, collect_data_files

# SPECPATH is the directory holding this spec file (injected by PyInstaller).
ENGINE_DIR = os.path.abspath(os.path.join(SPECPATH, "..", "engine"))

datas = []
binaries = []
hiddenimports = [
    "engines",
    "engines.common",
    "engines.curl_cffi_engine",
    "engines.cloudscraper_engine",
    "cookiejar",
]

# cloudscraper25 ships a data file (browsers.json) that is not found by static analysis,
# and runs its JavaScript challenge through js2py, which (with its pyjsparser dependency)
# ships data files PyInstaller's static analysis misses. curl_cffi ships a compiled libcurl
# and its own CA bundle. collect_all gathers the code, the binaries, and the data files for
# each. (pycryptodome, imported as "Crypto", has a built-in PyInstaller hook, so it is not
# listed here; add "Crypto" if a frozen run reports it missing.)
for package in ("cloudscraper25", "js2py", "pyjsparser", "curl_cffi"):
    pkg_datas, pkg_binaries, pkg_hidden = collect_all(package)
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hidden

# Bundle certifi's CA certificate file so HTTPS verification works in the frozen build.
datas += collect_data_files("certifi")

a = Analysis(
    [os.path.join(ENGINE_DIR, "main.py")],
    pathex=[ENGINE_DIR],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="cbcloudscraper",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="cbcloudscraper",
)
