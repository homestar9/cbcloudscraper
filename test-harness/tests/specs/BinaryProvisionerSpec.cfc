/**
 * Tests for BinaryProvisioner.
 *
 * These are hermetic: they never reach the network. They cover the resolution paths that do
 * not require a download — an explicit binary, a missing explicit binary, the "auto-download
 * off" error, and the version-stamp decision (a matching stamp is current, a stale one is not).
 * The real download path is verified by hand against a published GitHub Release.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		// The binary the local build produces, if present. Used for the short-circuit test.
		var localBinary    = expandPath( "/cbcloudscraper/bin/win64/cbcloudscraper.exe" );
		var hasLocalBinary = fileExists( localBinary );

		// Create a fake win64 binary (and optional version stamp) under a base directory.
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
				// Save the settings this suite changes, so each test starts clean.
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
					settings.autoDownloadBinary = false; // proves it did not download
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
				stageBinary( dir, "v0.0.1" ); // older than the wanted tag
				try {
					settings.binaryPath         = "";
					settings.binaryDirectory    = dir;
					settings.binaryReleaseTag   = "v1.0.0";
					settings.autoDownloadBinary = false; // so a stale binary surfaces as an error
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
					settings.binaryDirectory = ""; // default: the module's own bin/ folder
					// Compare with slashes normalized: both point to the same file, but the
					// provisioner joins path parts with "/" while expandPath uses "\".
					var resolved             = replace( provisioner.ensureBinary(), "\", "/", "all" );
					expect( resolved ).toBe( replace( localBinary, "\", "/", "all" ) );
				}
			);
		} );
	}

}
