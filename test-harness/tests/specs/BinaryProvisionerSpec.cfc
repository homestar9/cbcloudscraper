/**
 * Tests BinaryProvisioner without downloading files.
 *
 * These tests cover paths that do not need the network. They check a custom executable path, a
 * missing custom executable, disabled automatic downloads, and matching or outdated version tags.
 * Test the real download manually with a published GitHub Release.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		// Path to the executable created by a local Windows build
		var localBinary    = expandPath( "/cbcloudscraper/bin/win64/cbcloudscraper.exe" );
		var hasLocalBinary = fileExists( localBinary );

		// Create a fake Windows executable and optional version tag in a test directory.
		var stageBinary = function( required string baseDir, string tag = "" ){
			var platformDir = arguments.baseDir & "/win64";
			directoryCreate( platformDir, true, true );
			fileWrite( platformDir & "/cbcloudscraper.exe", "not a real binary" );
			if ( len( arguments.tag ) ) {
				fileWrite( platformDir & "/.cbcloudscraper-version", arguments.tag );
			}
		};

		describe( "BinaryProvisioner", function(){
			var provisioner = "";
			var settings    = "";
			var saved       = {};

			beforeEach( function(){
				provisioner = getInstance( "BinaryProvisioner@cbcloudscraper" );
				settings    = getInstance( dsl = "coldbox:moduleSettings:cbcloudscraper" );
				// Save shared settings so afterEach() can restore them after every test.
				saved       = {
					"binaryPath"         : settings.binaryPath,
					"binaryDirectory"    : settings.binaryDirectory,
					"binaryReleaseTag"   : settings.binaryReleaseTag,
					"autoDownloadBinary" : settings.autoDownloadBinary
				};
			} );

			afterEach( function(){
				settings.binaryPath         = saved.binaryPath;
				settings.binaryDirectory    = saved.binaryDirectory;
				settings.binaryReleaseTag   = saved.binaryReleaseTag;
				settings.autoDownloadBinary = saved.autoDownloadBinary;
			} );

			it( "returns an explicitly configured binary that exists", function(){
				var fake = getTempDirectory() & "cbcs-fake-" & createUUID() & ".exe";
				fileWrite( fake, "not a real binary" );
				try {
					settings.binaryPath = fake;
					expect( provisioner.ensureBinary() ).toBe( fake );
				} finally {
					fileDelete( fake );
				}
			} );

			it( "throws when the explicit binary path does not exist", function(){
				settings.binaryPath = "Z:/nope/cbcloudscraper.exe";
				expect( function(){
					provisioner.ensureBinary();
				} ).toThrow( type = "cbcloudscraper.BinaryUnavailable" );
			} );

			it( "throws when auto-download is off and no binary is present", function(){
				var emptyDir = getTempDirectory() & "cbcs-empty-" & createUUID();
				directoryCreate( emptyDir, true, true );
				try {
					settings.binaryPath         = "";
					settings.binaryDirectory    = emptyDir;
					settings.autoDownloadBinary = false;
					expect( function(){
						provisioner.ensureBinary();
					} ).toThrow( type = "cbcloudscraper.BinaryUnavailable" );
				} finally {
					directoryDelete( emptyDir, true );
				}
			} );

			it( "treats a binary with a matching version stamp as current (no download)", function(){
				var dir = getTempDirectory() & "cbcs-stamp-" & createUUID();
				stageBinary( dir, "v1.0.0" );
				try {
					settings.binaryPath         = "";
					settings.binaryDirectory    = dir;
					settings.binaryReleaseTag   = "v1.0.0";
					settings.autoDownloadBinary = false; // This test must use the existing executable.
					var resolved                = replace( provisioner.ensureBinary(), "\", "/", "all" );
					expect( resolved ).toBe(
						replace(
							dir & "/win64/cbcloudscraper.exe",
							"\",
							"/",
							"all"
						)
					);
				} finally {
					directoryDelete( dir, true );
				}
			} );

			it( "treats a binary with a stale version stamp as not current", function(){
				var dir = getTempDirectory() & "cbcs-stale-" & createUUID();
				stageBinary( dir, "v0.0.1" ); // This tag is older than the requested version.
				try {
					settings.binaryPath         = "";
					settings.binaryDirectory    = dir;
					settings.binaryReleaseTag   = "v1.0.0";
					settings.autoDownloadBinary = false; // Report the outdated cache instead of replacing it.
					expect( function(){
						provisioner.ensureBinary();
					} ).toThrow( type = "cbcloudscraper.BinaryUnavailable" );
				} finally {
					directoryDelete( dir, true );
				}
			} );

			it( "status() reports the installed and wanted versions and in-sync state", function(){
				var dir = getTempDirectory() & "cbcs-status-" & createUUID();
				stageBinary( dir, "v1.0.0" );
				try {
					settings.binaryPath       = "";
					settings.binaryDirectory  = dir;
					settings.binaryReleaseTag = "v1.0.0";
					var report                = provisioner.status();
					expect( report.present ).toBeTrue();
					expect( report.installedTag ).toBe( "v1.0.0" );
					expect( report.targetTag ).toBe( "v1.0.0" );
					expect( report.inSync ).toBeTrue();
				} finally {
					directoryDelete( dir, true );
				}
			} );

			it(
				title = "returns the locally built (unstamped) binary without downloading",
				skip  = !hasLocalBinary,
				body  = function(){
					settings.binaryPath      = "";
					settings.binaryDirectory = ""; // Use the module's bin directory.
					// Normalize separators before comparing the paths. The provisioner joins paths with
					// forward slashes, while expandPath uses Windows backslashes.
					var resolved             = replace( provisioner.ensureBinary(), "\", "/", "all" );
					expect( resolved ).toBe( replace( localBinary, "\", "/", "all" ) );
				}
			);
		} );
	}

}
