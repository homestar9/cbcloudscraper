/**
 * Calculates semantic versions for the bump task.
 *
 * This component does not read or write files. It receives a version string and returns a
 * new version string. Bump.cfc owns the command output and file changes.
 */
component {

	/**
	 * Returns the version levels accepted by Bump.cfc.
	 */
	string function supportedLevels(){
		return "major,minor,patch,prerelease,premajor,preminor,prepatch,none";
	}

	/**
	 * Splits a semantic version into its named parts.
	 *
	 * For example, 1.2.3-beta.4+build7 returns major 1, minor 2, patch 3,
	 * prerelease "beta.4", and build "build7".
	 *
	 * @version The version to parse.
	 */
	struct function parseVersion( required string version ){
		var remainingVersion = trim( arguments.version );
		var buildMetadata     = "";

		if ( find( "+", remainingVersion ) ) {
			var buildSeparator = find( "+", remainingVersion );
			buildMetadata       = mid( remainingVersion, buildSeparator + 1, len( remainingVersion ) );
			remainingVersion    = left( remainingVersion, buildSeparator - 1 );
		}

		var prerelease = "";
		if ( find( "-", remainingVersion ) ) {
			var prereleaseSeparator = find( "-", remainingVersion );
			prerelease              = mid( remainingVersion, prereleaseSeparator + 1, len( remainingVersion ) );
			remainingVersion         = left( remainingVersion, prereleaseSeparator - 1 );
		}

		var versionParts = listToArray( remainingVersion, "." );
		return {
			"major"      : val( versionParts[ 1 ] ?: "0" ),
			"minor"      : val( versionParts[ 2 ] ?: "0" ),
			"patch"      : val( versionParts[ 3 ] ?: "0" ),
			"prerelease" : prerelease,
			"build"      : buildMetadata
		};
	}

	/**
	 * Calculates the next version for one supported bump level.
	 *
	 * A normal bump finishes a matching prerelease. For example, a patch bump changes
	 * 1.2.3-beta.2 to 1.2.3. A prerelease bump changes beta.2 to beta.3.
	 *
	 * @current The current version.
	 * @level   A value returned by supportedLevels().
	 * @preid   The prerelease label. An empty value keeps the current label or starts "beta".
	 */
	string function nextVersion( required string current, required string level, string preid = "" ){
		var parsedVersion = parseVersion( arguments.current );
		var hasPrerelease = len( parsedVersion.prerelease ) > 0;
		var label          = len( arguments.preid ) ? arguments.preid : "beta";

		switch ( arguments.level ) {
			case "major":
				if ( hasPrerelease && parsedVersion.minor == 0 && parsedVersion.patch == 0 ) {
					return "#parsedVersion.major#.0.0";
				}
				return "#parsedVersion.major + 1#.0.0";

			case "minor":
				if ( hasPrerelease && parsedVersion.patch == 0 ) {
					return "#parsedVersion.major#.#parsedVersion.minor#.0";
				}
				return "#parsedVersion.major#.#parsedVersion.minor + 1#.0";

			case "patch":
				if ( hasPrerelease ) {
					return "#parsedVersion.major#.#parsedVersion.minor#.#parsedVersion.patch#";
				}
				return "#parsedVersion.major#.#parsedVersion.minor#.#parsedVersion.patch + 1#";

			case "premajor":
				return "#parsedVersion.major + 1#.0.0-#label#.1";

			case "preminor":
				return "#parsedVersion.major#.#parsedVersion.minor + 1#.0-#label#.1";

			case "prepatch":
				return "#parsedVersion.major#.#parsedVersion.minor#.#parsedVersion.patch + 1#-#label#.1";

			case "prerelease":
				return incrementPrerelease( parsedVersion, arguments.preid );
		}

		return arguments.current;
	}

	/**
	 * Increases the number at the end of a prerelease label.
	 */
	private string function incrementPrerelease( required struct parsedVersion, string preid = "" ){
		var coreVersion = "#arguments.parsedVersion.major#.#arguments.parsedVersion.minor#.#arguments.parsedVersion.patch#";

		if ( !len( arguments.parsedVersion.prerelease ) ) {
			throw(
				type    = "BuildVersion.NotPrerelease",
				message = "#coreVersion# is not a prerelease, so there is nothing to step forward."
			);
		}

		var labelParts = listToArray( arguments.parsedVersion.prerelease, "." );
		var label      = arguments.parsedVersion.prerelease;
		var counter    = 0;

		if ( arrayLen( labelParts ) > 1 && isNumeric( labelParts[ arrayLen( labelParts ) ] ) ) {
			counter = val( labelParts[ arrayLen( labelParts ) ] );
			arrayDeleteAt( labelParts, arrayLen( labelParts ) );
			label = arrayToList( labelParts, "." );
		}

		if ( len( arguments.preid ) && arguments.preid != label ) {
			return "#coreVersion#-#arguments.preid#.1";
		}

		return "#coreVersion#-#label#.#counter + 1#";
	}
}
