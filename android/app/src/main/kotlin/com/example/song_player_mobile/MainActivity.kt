package com.example.song_player_mobile

import android.Manifest
import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "com.example.song_player_mobile/offline_audio"
    private val PERMISSION_REQUEST_CODE = 1001
    private val DELETE_REQUEST_CODE = 1002
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingDeleteResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestStoragePermission" -> {
                    val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        Manifest.permission.READ_MEDIA_AUDIO
                    } else {
                        Manifest.permission.READ_EXTERNAL_STORAGE
                    }

                    if (ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        ActivityCompat.requestPermissions(this, arrayOf(permission), PERMISSION_REQUEST_CODE)
                    }
                }
                "hasAllFilesAccess" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        result.success(Environment.isExternalStorageManager())
                    } else {
                        result.success(true)
                    }
                }
                "requestAllFilesAccess" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                                data = Uri.parse("package:$packageName")
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("ERROR", e2.message, null)
                            }
                        }
                    } else {
                        result.success(true)
                    }
                }
                "getAudioFiles" -> {
                    Thread {
                        try {
                            val songs = fetchAllAudioFiles()
                            runOnUiThread {
                                result.success(songs)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.success(emptyList<Map<String, Any?>>())
                            }
                        }
                    }.start()
                }
                "deleteAudioFile" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        val file = File(path)
                        // 1. Try direct file deletion if file exists and can be deleted
                        var deleted = false
                        try {
                            if (file.exists()) {
                                deleted = file.delete()
                            }
                        } catch (_: Exception) {}

                        if (deleted || !file.exists()) {
                            try {
                                contentResolver.delete(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, "${MediaStore.Audio.Media.DATA} = ?", arrayOf(path))
                                MediaScannerConnection.scanFile(this, arrayOf(path), null, null)
                            } catch (_: Exception) {}
                            result.success(true)
                            return@setMethodCallHandler
                        }

                        // 2. Scoped Storage: Try MediaStore delete request
                        val contentUri = getAudioContentUri(path)
                        if (contentUri != null) {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                try {
                                    val pendingIntent = MediaStore.createDeleteRequest(contentResolver, listOf(contentUri))
                                    pendingDeleteResult = result
                                    startIntentSenderForResult(pendingIntent.intentSender, DELETE_REQUEST_CODE, null, 0, 0, 0)
                                    return@setMethodCallHandler
                                } catch (_: Exception) {}
                            } else if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
                                try {
                                    contentResolver.delete(contentUri, null, null)
                                    result.success(true)
                                    return@setMethodCallHandler
                                } catch (e: RecoverableSecurityException) {
                                    pendingDeleteResult = result
                                    startIntentSenderForResult(e.userAction.actionIntent.intentSender, DELETE_REQUEST_CODE, null, 0, 0, 0)
                                    return@setMethodCallHandler
                                } catch (_: Exception) {}
                            }
                        }

                        // 3. If still not deleted and Android 11+, check if All Files Access is needed
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
                            result.error("ALL_FILES_ACCESS_REQUIRED", "All files access permission required to delete this file", null)
                            return@setMethodCallHandler
                        }

                        result.success(false)
                    } else {
                        result.error("INVALID_PATH", "Path is null", null)
                    }
                }
                "renameAudioFile" -> {
                    val path = call.argument<String>("path")
                    val newName = call.argument<String>("newName")
                    if (path != null && newName != null) {
                        try {
                            val file = File(path)
                            if (file.exists()) {
                                val parent = file.parentFile
                                val ext = file.extension
                                val newFile = if (ext.isNotEmpty()) File(parent, "$newName.$ext") else File(parent, newName)
                                val success = file.renameTo(newFile)
                                if (success) {
                                    try {
                                        val values = ContentValues().apply {
                                            put(MediaStore.Audio.Media.DATA, newFile.absolutePath)
                                            put(MediaStore.Audio.Media.TITLE, newName)
                                            put(MediaStore.Audio.Media.DISPLAY_NAME, newFile.name)
                                        }
                                        contentResolver.update(
                                            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                                            values,
                                            "${MediaStore.Audio.Media.DATA} = ?",
                                            arrayOf(path)
                                        )
                                        MediaScannerConnection.scanFile(this, arrayOf(path, newFile.absolutePath), null, null)
                                    } catch (_: Exception) {}
                                    result.success(newFile.absolutePath)
                                } else {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
                                        result.error("ALL_FILES_ACCESS_REQUIRED", "All files access permission required to rename this file", null)
                                    } else {
                                        result.success(null)
                                    }
                                }
                            } else {
                                result.error("NOT_FOUND", "File does not exist", null)
                            }
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGS", "Missing arguments", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == DELETE_REQUEST_CODE) {
            val success = (resultCode == Activity.RESULT_OK)
            pendingDeleteResult?.success(success)
            pendingDeleteResult = null
        }
    }

    private fun getAudioContentUri(path: String): Uri? {
        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(MediaStore.Audio.Media._ID)
        val selection = "${MediaStore.Audio.Media.DATA} = ?"
        val selectionArgs = arrayOf(path)
        try {
            contentResolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID))
                    return ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
                }
            }
        } catch (_: Exception) {}
        return null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    private fun fetchAllAudioFiles(): List<Map<String, Any?>> {
        val songList = mutableListOf<Map<String, Any?>>()
        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.SIZE
        )
        val selection = "${MediaStore.Audio.Media.DURATION} >= 10000 AND " +
            "${MediaStore.Audio.Media.SIZE} > 0 AND " +
            "${MediaStore.Audio.Media.DATA} NOT LIKE '%WhatsApp%' AND " +
            "${MediaStore.Audio.Media.DATA} NOT LIKE '%whatsapp%' AND " +
            "${MediaStore.Audio.Media.DATA} NOT LIKE '%com.whatsapp%' AND " +
            "${MediaStore.Audio.Media.DATA} NOT LIKE '%.opus'"
        val sortOrder = "${MediaStore.Audio.Media.TITLE} ASC"

        try {
            val cursor = contentResolver.query(uri, projection, selection, null, sortOrder)
            cursor?.use { c ->
                val idCol = c.getColumnIndex(MediaStore.Audio.Media._ID)
                val titleCol = c.getColumnIndex(MediaStore.Audio.Media.TITLE)
                val artistCol = c.getColumnIndex(MediaStore.Audio.Media.ARTIST)
                val albumCol = c.getColumnIndex(MediaStore.Audio.Media.ALBUM)
                val durationCol = c.getColumnIndex(MediaStore.Audio.Media.DURATION)
                val dataCol = c.getColumnIndex(MediaStore.Audio.Media.DATA)
                val nameCol = c.getColumnIndex(MediaStore.Audio.Media.DISPLAY_NAME)

                while (c.moveToNext()) {
                    val id = if (idCol != -1) c.getLong(idCol) else 0L
                    val title = if (titleCol != -1) c.getString(titleCol) ?: "" else ""
                    val artist = if (artistCol != -1) c.getString(artistCol) ?: "" else ""
                    val album = if (albumCol != -1) c.getString(albumCol) ?: "" else ""
                    val durationMs = if (durationCol != -1) c.getLong(durationCol) else 0L
                    val path = if (dataCol != -1) c.getString(dataCol) ?: "" else ""
                    val name = if (nameCol != -1) c.getString(nameCol) ?: "" else ""

                    if (path.isEmpty()) continue

                    val lowerPath = path.lowercase()
                    if (lowerPath.contains("whatsapp") || lowerPath.contains("com.whatsapp") || lowerPath.endsWith(".opus")) {
                        continue
                    }

                    val file = File(path)
                    if (file.exists() && file.length() > 0) {
                        val displayName = if (title.isNotBlank()) {
                            title
                        } else if (name.isNotBlank()) {
                            name
                        } else {
                            file.nameWithoutExtension
                        }

                        songList.add(
                            mapOf(
                                "id" to id.toString(),
                                "title" to displayName,
                                "artist" to if (artist.isNotBlank() && artist != "<unknown>") artist else "Device Audio",
                                "album" to if (album.isNotBlank() && album != "<unknown>") album else "Device Storage",
                                "duration" to (durationMs / 1000).toInt(),
                                "path" to path
                            )
                        )
                    }
                }
            }
        } catch (_: Exception) {}
        return songList
    }
}
