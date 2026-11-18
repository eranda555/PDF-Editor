package com.hundredpercentpdf.hundred_percent_pdf

import android.view.WindowManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.core.content.IntentCompat
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val pendingImports = mutableListOf<Map<String,String>>()
    private var importsChannel: MethodChannel? = null
    private val importExecutor=Executors.newSingleThreadExecutor()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        acceptShare(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        acceptShare(intent)
    }
    private fun acceptShare(intent: Intent?) {
        if (intent == null) return
        val uris = when(intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent,Intent.EXTRA_STREAM,Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE -> IntentCompat.getParcelableArrayListExtra(intent,Intent.EXTRA_STREAM,Uri::class.java) ?: emptyList()
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            else -> emptyList()
        }
        importExecutor.execute {
        for (uri in uris.take(20)) {
            if (uri.scheme != "content") continue
            val extension = when(contentResolver.getType(uri)) {
                "application/pdf" -> "pdf"
                "image/jpeg" -> "jpg"
                "image/png" -> "png"
                "image/webp" -> "webp"
                "image/tiff" -> "tiff"
                else -> continue
            }
            val output = File(cacheDir,UUID.randomUUID().toString()+"."+extension)
            try {
                contentResolver.openInputStream(uri)?.use { input ->
                    output.outputStream().use { destination ->
                        val buffer=ByteArray(65536); var total=0L
                        while(true) {
                            val read=input.read(buffer);if(read<0) break
                            total+=read;if(total>150L*1024*1024) throw IllegalArgumentException("Import size exceeded")
                            destination.write(buffer,0,read)
                        }
                    }
                } ?: throw IllegalArgumentException("Unreadable input")
                runOnUiThread {
                    pendingImports.add(mapOf("path" to output.absolutePath,"name" to "Shared document.$extension"))
                    importsChannel?.invokeMethod("available",null)
                }
            } catch (error: Exception) {output.delete()}
        }
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val identity=DeviceIdentity()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"pdf_suite/identity").setMethodCallHandler { call,result ->
            try {
                when(call.method) {
                    "publicKey" -> result.success(identity.publicKey())
                    "sign" -> result.success(identity.sign(call.argument<String>("message") ?: throw IllegalArgumentException("Message required")))
                    else -> result.notImplemented()
                }
            } catch(error:Exception) {result.error("identity_unavailable","Hardware-backed device identity unavailable",null)}
        }
        importsChannel=MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"pdf_suite/imports")
        importsChannel?.setMethodCallHandler { call,result ->
            if(call.method=="takePending") {val items=pendingImports.toList();pendingImports.clear();result.success(items)}
            else result.notImplemented()
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pdf_suite/privacy")
            .setMethodCallHandler { call, result ->
                if (call.method == "protectScreen") {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                } else result.notImplemented()
            }
        // ML Kit's scanner channel is registered by GeneratedPluginRegistrant.
    }
}
