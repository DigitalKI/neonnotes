package com.neonnotes.openwith;

import android.app.Activity;
import android.content.ClipData;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Bundle;
import android.os.Parcelable;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;

/**
 * Android entry point for "Open with NeonNotes" on Markdown documents.
 *
 * <p>Godot does not expose the activity's launch intent to GDScript, so this
 * lightweight no-display activity receives {@link Intent#ACTION_VIEW}, rewrites
 * the payload as {@link Intent#ACTION_SEND}, and starts the real Godot launcher.
 * The existing SharePlugin already knows how to copy an {@code ACTION_SEND}
 * file URI into its cache and emit {@code share_received}; that lets the
 * GDScript {@code ShareIntake} import the file exactly like a shared one.</p>
 *
 * <p>Why not declare the VIEW filter on the Godot activity itself? The exported
 * Godot activity is not exported to other apps, and Godot's export plugin
 * inserts manifest additions before the main activity, so an activity-alias
 * added there fails PackageParser validation. A standalone activity has no such
 * ordering constraint and can stay enabled independently of the share-target
 * toggle.</p>
 */
public class MarkdownOpenActivity extends Activity {
    private static final String LOG_TAG = "godot::MarkdownOpenActivity";
    private static final String DEFAULT_MIME = "text/markdown";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        forwardOpenIntent(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        forwardOpenIntent(intent);
    }

    private void forwardOpenIntent(Intent received) {
        if (received == null) {
            Log.w(LOG_TAG, "forwardOpenIntent(): received intent is null.");
            finish();
            return;
        }

        ComponentName main = resolveGodotActivity();
        if (main == null) {
            Log.e(LOG_TAG, "forwardOpenIntent(): could not resolve the Godot launcher activity"
                    + " for package '" + getPackageName() + "'.");
            finish();
            return;
        }

        ArrayList<Uri> uris = collectUris(received);
        CharSequence textChars = received.getCharSequenceExtra(Intent.EXTRA_TEXT);
        String text = textChars == null ? null : textChars.toString();
        if (uris.isEmpty() && (text == null || text.isEmpty())) {
            Log.w(LOG_TAG, "forwardOpenIntent(): intent carried no URI or text.");
            finish();
            return;
        }

        Intent forward = buildSendIntent(received, uris, text);
        forward.setComponent(main);
        forward.addFlags(
                // Bring an existing singleInstancePerTask Godot task forward, or
                // create one when the app is cold.
                Intent.FLAG_ACTIVITY_NEW_TASK
                // Deliver via onNewIntent when the Godot activity is already on top.
                | Intent.FLAG_ACTIVITY_SINGLE_TOP
                // Keep the sender's content:// grant valid for the Godot process.
                | Intent.FLAG_GRANT_READ_URI_PERMISSION);

        Log.d(LOG_TAG, "forwardOpenIntent(): forwarding " + uris.size() + " URI(s) to "
                + main.flattenToShortString());
        try {
            startActivity(forward);
        } catch (Exception e) {
            Log.e(LOG_TAG, "forwardOpenIntent(): could not start Godot activity: "
                    + e.getMessage(), e);
        }
        // Theme.NoDisplay activities must finish before onResume returns.
        finish();
    }

    private Intent buildSendIntent(Intent received, ArrayList<Uri> uris, String text) {
        Intent forward;
        if (uris.size() > 1) {
            forward = new Intent(Intent.ACTION_SEND_MULTIPLE);
            forward.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
            ClipData clip = ClipData.newRawUri("", uris.get(0));
            for (int i = 1; i < uris.size(); i++) {
                clip.addItem(new ClipData.Item(uris.get(i)));
            }
            forward.setClipData(clip);
        } else if (uris.size() == 1) {
            forward = new Intent(Intent.ACTION_SEND);
            forward.putExtra(Intent.EXTRA_STREAM, uris.get(0));
            forward.setClipData(ClipData.newRawUri("", uris.get(0)));
        } else {
            forward = new Intent(Intent.ACTION_SEND);
        }

        String mime = received.getType();
        if ((mime == null || mime.isEmpty()) && !uris.isEmpty()) {
            try {
                mime = getContentResolver().getType(uris.get(0));
            } catch (Exception e) {
                Log.w(LOG_TAG, "buildSendIntent(): could not resolve type: " + e.getMessage());
            }
        }
        if (mime == null || mime.isEmpty()) {
            mime = DEFAULT_MIME;
        }
        // Some file managers label a .md file as text/plain or
        // application/octet-stream. If the URI still carries the extension,
        // report Markdown so the intake can recognise it even when the provider
        // supplies no display name for the cache copy.
        if (!uris.isEmpty()) {
            String segment = uris.get(0).getLastPathSegment();
            if (segment != null) {
                String lower = segment.toLowerCase();
                if (lower.endsWith(".md") || lower.endsWith(".markdown")) {
                    mime = DEFAULT_MIME;
                }
            }
        }
        forward.setType(mime);

        if (uris.isEmpty() && text != null && !text.isEmpty()) {
            forward.putExtra(Intent.EXTRA_TEXT, text);
            CharSequence subject = received.getCharSequenceExtra(Intent.EXTRA_SUBJECT);
            if (subject != null) {
                forward.putExtra(Intent.EXTRA_SUBJECT, subject.toString());
            }
        }
        return forward;
    }

    @SuppressWarnings("deprecation")
    private static ArrayList<Uri> collectUris(Intent intent) {
        ArrayList<Uri> uris = new ArrayList<>();

        Uri data = intent.getData();
        if (data != null) {
            uris.add(data);
        }

        ClipData clip = intent.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                Uri uri = clip.getItemAt(i).getUri();
                if (uri != null && !uris.contains(uri)) {
                    uris.add(uri);
                }
            }
        }

        Parcelable stream = intent.getParcelableExtra(Intent.EXTRA_STREAM);
        addStream(uris, stream);
        return uris;
    }

    private static void addStream(ArrayList<Uri> uris, Parcelable stream) {
        if (stream instanceof Uri) {
            Uri uri = (Uri) stream;
            if (!uris.contains(uri)) {
                uris.add(uri);
            }
        } else if (stream instanceof ArrayList) {
            for (Object item : (ArrayList<?>) stream) {
                if (item instanceof Uri && !uris.contains(item)) {
                    uris.add((Uri) item);
                }
            }
        }
    }

    /**
     * Resolves the app's launcher activity at runtime, matching SharePlugin's
     * own approach so this stays compatible with Godot's generated activity
     * class names and activity-alias.
     */
    private ComponentName resolveGodotActivity() {
        Intent queryIntent = new Intent(Intent.ACTION_MAIN);
        queryIntent.addCategory(Intent.CATEGORY_LAUNCHER);
        queryIntent.setPackage(getPackageName());
        List<ResolveInfo> results = getPackageManager()
                .queryIntentActivities(queryIntent, PackageManager.MATCH_DEFAULT_ONLY);
        if (results == null || results.isEmpty()) {
            return null;
        }
        ActivityInfo info = results.get(0).activityInfo;
        return new ComponentName(info.packageName, info.name);
    }
}
