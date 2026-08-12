/**
 * Tests for BinaryDownloader's pure helpers.
 *
 * Hermetic and OS-agnostic: no network, and assertions are built from the platform this test
 * happens to run on, so they hold on Windows (dev) and Linux (CI) alike. The actual download
 * is exercised by hand against a published GitHub Release, not here.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		var moduleRoot    = expandPath( "/cbcloudscraper" );
		var moduleVersion = deserializeJSON( fileRead( expandPath( "/cbcloudscraper/box.json" ), "utf-8" ) ).version;

		describe( "BinaryDownloader", function(){
			var downloader = "";
			var platform   = "";

			beforeEach( function(){
				downloader = getInstance( "BinaryDownloader@cbcloudscraper" );
				platform   = downloader.getPlatform();
			} );

			it( "reports a self-consistent platform", function(){
				expect( platform.asset ).toBe( "cbcloudscraper-" & platform.dir & ".zip" );
				expect( platform.exe ).toInclude( "cbcloudscraper" );
			} );

			it( "derives the release base URL from box.json repository.url", function(){
				expect( downloader.deriveBaseURL( moduleRoot ) ).toBe( "https://github.com/homestar9/cbcloudscraper/releases/download" );
			} );

			it( "uses an override base URL and trims a trailing slash", function(){
				expect( downloader.deriveBaseURL( moduleRoot, "https://example.com/dl/" ) ).toBe( "https://example.com/dl" );
			} );

			it( "resolves the release tag from the module version, or an override", function(){
				expect( downloader.resolveTag( moduleRoot ) ).toBe( "v" & moduleVersion );
				expect( downloader.resolveTag( moduleRoot, "v9.9.9" ) ).toBe( "v9.9.9" );
			} );

			it( "reads the module version from box.json", function(){
				expect( downloader.readModuleVersion( moduleRoot ) ).toBe( moduleVersion );
			} );

			it( "reports presence, stamp, and currency for a cached binary", function(){
				var dir     = getTempDirectory() & "cbcs-dl-" & createUUID();
				var platDir = dir & "/" & platform.dir;
				try {
					// Nothing there yet.
					expect( downloader.isPresent( dir ) ).toBeFalse();
					expect( downloader.installedTag( dir ) ).toBe( "" );
					expect( downloader.isCurrent( dir, "v1.0.0" ) ).toBeFalse();

					// Unstamped binary present: usable, counts as current for any tag.
					directoryCreate( platDir, true, true );
					fileWrite( platDir & "/" & platform.exe, "not a real binary" );
					expect( downloader.isPresent( dir ) ).toBeTrue();
					expect( downloader.installedTag( dir ) ).toBe( "" );
					expect( downloader.isCurrent( dir, "v1.0.0" ) ).toBeTrue();

					// Stamped binary: current only for the matching tag.
					fileWrite( platDir & "/.cbcloudscraper-version", "v1.0.0" );
					expect( downloader.installedTag( dir ) ).toBe( "v1.0.0" );
					expect( downloader.isCurrent( dir, "v1.0.0" ) ).toBeTrue();
					expect( downloader.isCurrent( dir, "v2.0.0" ) ).toBeFalse();
				} finally {
					directoryDelete( dir, true );
				}
			} );

			it( "builds the binary path from the base dir and platform", function(){
				var path = replace(
					downloader.binaryPathFor( "C:/tmp/base" ),
					"\",
					"/",
					"all"
				);
				expect( path ).toBe( "C:/tmp/base/" & platform.dir & "/" & platform.exe );
			} );
		} );
	}

}
