component extends="coldbox.system.ioc.config.Binder"{

	/** Configure dependency injection for the test application. */
	function configure(){

		// Main WireBox settings
		wireBox = {
			// Store the WireBox injector in application.wireBox.
			scopeRegistration = {
				enabled = true,
				scope   = "application", // Other valid scopes are server, cluster, and session.
				key		= "wireBox"
			},

			// Custom dependency-injection namespaces
			customDSL = {
				// Example: namespace = "mapping name"
			},

			// Custom object scopes
			customScopes = {
				// Example: annotationName = "mapping name"
			},

			// Packages that WireBox should scan for components
			scanLocations = [],

			// Classes where recursive dependency lookup should stop
			stopRecursions = [],

			// Optional parent injector object
			parentInjector = "",

			// Event listeners, created in the listed order
			listeners = [
				// Example: { class="", name="", properties={} }
			]
		};

		// Add test-specific dependency bindings here.
	}

}
