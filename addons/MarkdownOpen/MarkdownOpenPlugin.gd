@tool
extends EditorPlugin
## Registers NeonNotes as an Android "Open with" handler for Markdown files.
##
## The runtime side is deliberately small: the injected activity receives
## ACTION_VIEW, rewrites it as ACTION_SEND and starts the normal Godot launcher.
## SharePlugin already copies ACTION_SEND file URIs into its cache, and
## ShareIntake routes them into the Inbox, so no second GDScript bridge is
## needed. This activity is always enabled and is independent of the
## Share-to-NeonNotes setting.

var android_export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	android_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(android_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(android_export_plugin)
	android_export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	const PLUGIN_NAME := "MarkdownOpen"
	const ACTIVITY_CLASS := "com.neonnotes.openwith.MarkdownOpenActivity"

	## One always-enabled activity with VIEW filters for the MIME types Android
	## file managers use for .md. text/plain and application/octet-stream are
	## narrowed with pathPattern so NeonNotes is not offered for every text or
	## binary file. A */* pathPattern entry catches managers that report a
	## generic type but keep the .md name in the URI path.
	const ACTIVITY_TAG := """
<activity
		android:name="%s"
		android:enabled="true"
		android:exported="true"
		android:noHistory="true"
		android:excludeFromRecents="true"
		android:theme="@android:style/Theme.NoDisplay">
	<intent-filter>
		<action android:name="android.intent.action.VIEW" />
		<category android:name="android.intent.category.DEFAULT" />
		<data android:scheme="content" />
		<data android:scheme="file" />
		<data android:mimeType="text/markdown" />
	</intent-filter>
	<intent-filter>
		<action android:name="android.intent.action.VIEW" />
		<category android:name="android.intent.category.DEFAULT" />
		<data android:scheme="content" />
		<data android:scheme="file" />
		<data android:mimeType="text/x-markdown" />
	</intent-filter>
	<intent-filter>
		<action android:name="android.intent.action.VIEW" />
		<category android:name="android.intent.category.DEFAULT" />
		<data android:scheme="content" />
		<data android:scheme="file" />
		<data android:mimeType="application/markdown" />
	</intent-filter>
	<intent-filter>
		<action android:name="android.intent.action.VIEW" />
		<category android:name="android.intent.category.DEFAULT" />
		<data android:scheme="content" />
		<data android:scheme="file" />
		<data android:mimeType="text/plain" android:pathPattern=".*[.]md" />
		<data android:mimeType="text/plain" android:pathPattern=".*[.]markdown" />
	</intent-filter>
	<intent-filter>
		<action android:name="android.intent.action.VIEW" />
		<category android:name="android.intent.category.DEFAULT" />
		<data android:scheme="content" />
		<data android:scheme="file" />
		<data android:mimeType="application/octet-stream" android:pathPattern=".*[.]md" />
		<data android:mimeType="application/octet-stream" android:pathPattern=".*[.]markdown" />
	</intent-filter>
	<intent-filter>
		<action android:name="android.intent.action.VIEW" />
		<category android:name="android.intent.category.DEFAULT" />
		<data android:scheme="content" />
		<data android:scheme="file" />
		<data android:mimeType="*/*" android:pathPattern=".*[.]md" />
		<data android:mimeType="*/*" android:pathPattern=".*[.]markdown" />
	</intent-filter>
</activity>
"""


	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid


	func _get_name() -> String:
		return PLUGIN_NAME


	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var kind := "debug" if debug else "release"
		return PackedStringArray([
			"%s/bin/%s/%s-%s.aar" % [PLUGIN_NAME, kind, PLUGIN_NAME, kind]
		])


	func _get_android_manifest_application_element_contents(
		platform: EditorExportPlatform, _debug: bool
	) -> String:
		return ACTIVITY_TAG % ACTIVITY_CLASS
