/**
 * Tests the CloudScraper model.
 *
 * Most tests inject MockRunner, so they work on any CFML engine and operating system without the
 * real executable. They cover request building, response decoding, headers, cookies, and process
 * failures. The final test uses the real executable and is skipped when that file is not built.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		// Check the default Windows build path before enabling the live executable test.
		var hasBinary = fileExists( expandPath( "/cbcloudscraper/bin/win64/cbcloudscraper.exe" ) );

		describe( "CloudScraper", function(){
			var cs         = "";
			var mockRunner = "";
			var realRunner = "";

			beforeEach( function(){
				cs         = getInstance( "CloudScraper@cbcloudscraper" );
				realRunner = cs.getRunner(); // Save the real runner so afterEach() can restore it.
				mockRunner = new tests.resources.MockRunner();
				cs.setRunner( mockRunner ); // Prevent unit tests from starting the real executable.
			} );

			afterEach( function(){
				// CloudScraper is a singleton. Restore the runner so this test cannot affect later tests.
				cs.setRunner( realRunner );
			} );

			it( "returns a decoded body, status, headers and cookies on success", function(){
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeTrue();
				expect( result.statusCode ).toBe( 200 );
				expect( result.engineUsed ).toBe( "curl_cffi" );
				expect( result.fileContent ).toBe( "Hello, cbcloudscraper!" );
				expect( result.charset ).toBe( "utf-8" );

				// Check the simple header struct and the complete ordered header list.
				expect( result.headers ).toHaveKey( "Content-Type" );
				expect( result.rawHeaders.len() ).toBe( 2 );

				expect( result.cookies.len() ).toBe( 1 );
				expect( result.cookies[ 1 ].name ).toBe( "cf_clearance" );
			} );

			it( "sends the method, engine, and a URL-encoded form body for post()", function(){
				cs.post(
					url     = "https://example.com/submit",
					body    = { "a" : "1", "b" : "2" },
					options = { "engine" : "curl_cffi" }
				);

				var sent = mockRunner.getLastRequest();
				expect( sent.method ).toBe( "POST" );
				expect( sent.engine ).toBe( "curl_cffi" );

				var decodedBody = charsetEncode( binaryDecode( sent.bodyBase64, "base64" ), "utf-8" );
				expect( decodedBody ).toInclude( "a=1" );
				expect( decodedBody ).toInclude( "b=2" );
			} );

			it( "applies per-request options and extra headers", function(){
				cs.get(
					url     = "https://example.com",
					options = {
						"timeout"     : 15,
						"impersonate" : "chrome131",
						"headers"     : { "X-Test" : "yes" }
					}
				);

				var sent = mockRunner.getLastRequest();
				expect( sent.timeoutSeconds ).toBe( 15 );
				expect( sent.impersonate ).toBe( "chrome131" );
				expect( sent.headers[ "X-Test" ] ).toBe( "yes" );
			} );

			it( "returns ok=false with a timeout message when the process times out", function(){
				mockRunner.setBehavior( "timeout" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( result.statusCode ).toBe( 0 );
				expect( result.errorDetail ).toInclude( "timeout" );
				// A failure result keeps the same types as a success result.
				expect( isBinary( result.fileContentAsBinary ) ).toBeTrue();
			} );

			it( "returns ok=false when no response file is produced", function(){
				mockRunner.setBehavior( "noFile" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( result.errorDetail ).toInclude( "no response" );
			} );

			it( "returns ok=false when the worker reports an error", function(){
				mockRunner.setBehavior( "errorResponse" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( result.errorDetail ).toInclude( "boom" );
			} );

			it( "returns ok=false when the response is malformed", function(){
				mockRunner.setBehavior( "malformed" );
				var result = cs.get( "https://example.com" );

				expect( result.ok ).toBeFalse();
				expect( len( result.errorDetail ) ).toBeGT( 0 );
			} );

			it( "throws when throwOnError is set and an operational error occurs", function(){
				mockRunner.setBehavior( "timeout" );
				expect( function(){
					cs.get( url = "https://example.com", options = { "throwOnError" : true } );
				} ).toThrow( type = "cbcloudscraper.RequestException" );
			} );

			it( "returns ok=false when an explicitly set binary path does not exist", function(){
				var settings        = getInstance( dsl = "coldbox:moduleSettings:cbcloudscraper" );
				var original        = settings.binaryPath;
				settings.binaryPath = "Z:/does/not/exist/cbcloudscraper.exe";
				try {
					var result = cs.get( "https://example.com" );
					expect( result.ok ).toBeFalse();
					expect( result.errorDetail ).toInclude( "does not exist" );
				} finally {
					settings.binaryPath = original;
				}
			} );

			it(
				title = "fetches a live URL through the real binary (Windows, built binary only)",
				skip  = !hasBinary,
				body  = function(){
					// Use the real process runner for this integration test.
					cs.setRunner( getInstance( "ProcessRunner@cbcloudscraper" ) );

					var result = cs.get( "https://example.com" );

					expect( result.ok ).toBeTrue();
					expect( result.statusCode ).toBe( 200 );
					expect( result.fileContent ).toInclude( "Example Domain" );
					expect( result.engineUsed ).toBe( "curl_cffi" );
				}
			);
		} );
	}

}
