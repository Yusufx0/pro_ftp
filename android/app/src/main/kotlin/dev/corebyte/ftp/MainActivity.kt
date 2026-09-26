package com.topreqapps.ftpdesk

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import org.apache.commons.net.ftp.FTPSClient
import org.apache.commons.net.io.CopyStreamAdapter
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.time.Duration

class MainActivity: FlutterActivity() {
    private val CHANNEL = "ftp_native"
    private var ftpClient: FTPClient? = null
    private var methodChannel: MethodChannel? = null
    
    @Volatile
    private var isTransferCancelled = false
    
    private val ioScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        methodChannel?.setMethodCallHandler { call, result ->
            ioScope.launch {
                try {
                    when (call.method) {
                        "connect" -> handleConnect(call.arguments as Map<String, Any>, result)
                        "noop" -> {
                            val isAlive = try { ftpClient?.sendNoOp() == true } catch (e: Exception) { false }
                            withContext(Dispatchers.Main) { result.success(isAlive) }
                        }
                        "disconnect" -> {
                            try {
                                if (ftpClient?.isConnected == true) {
                                    try { ftpClient?.logout() } catch (e: Exception) {}
                                    try { ftpClient?.disconnect() } catch (e: Exception) {}
                                }
                            } catch (e: Exception) {}
                            withContext(Dispatchers.Main) { result.success(null) }
                        }
                        "cancel" -> {
                            isTransferCancelled = true
                            withContext(Dispatchers.Main) { result.success(null) }
                        }
                        "list" -> handleList(call.argument<String>("path") ?: "/", result)
                        "cd" -> {
                            val path = call.argument<String>("path") ?: "/"
                            val success = ftpClient?.changeWorkingDirectory(path) ?: false
                            if(!success) throw Exception("Path not found")
                            withContext(Dispatchers.Main) { result.success(null) }
                        }
                        "mkdir" -> {
                            val name = call.argument<String>("name") ?: ""
                            val success = ftpClient?.makeDirectory(name) ?: false
                            if(!success) throw Exception("Could not create directory")
                            withContext(Dispatchers.Main) { result.success(null) }
                        }
                        "delete" -> {
                            val name = call.argument<String>("name") ?: ""
                            val isDir = call.argument<Boolean>("isDir") ?: false
                            val success = if (isDir) ftpClient?.removeDirectory(name) else ftpClient?.deleteFile(name)
                            if (success != true) throw Exception("Delete failed")
                            withContext(Dispatchers.Main) { result.success(null) }
                        }
                        "rename" -> {
                            val old = call.argument<String>("old") ?: ""
                            val new = call.argument<String>("new") ?: ""
                            val success = ftpClient?.rename(old, new) ?: false
                            if(!success) throw Exception("Rename failed")
                            withContext(Dispatchers.Main) { result.success(null) }
                        }
                        "upload" -> handleUpload(call.arguments as Map<String, Any>, result)
                        "download" -> handleDownload(call.arguments as Map<String, Any>, result)
                        else -> withContext(Dispatchers.Main) { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    val msg = e.message ?: "Unknown error"
                    withContext(Dispatchers.Main) { 
                        if (msg == "CANCELLED") {
                            result.error("CANCELLED", msg, null)
                        } else {
                            result.error("FTP_ERR", msg, null)
                        }
                    }
                }
            }
        }
    }

    private suspend fun handleConnect(args: Map<String, Any>, result: MethodChannel.Result) {
        val mode = args["mode"] as? String ?: "FTP"
        val host = args["host"] as? String ?: return
        val port = args["port"] as? Int ?: 21
        val user = args["user"] as? String ?: "anonymous"
        val pass = args["pass"] as? String ?: ""

        ftpClient = when {
            mode.contains("FTPES") -> FTPSClient(false)
            mode.contains("FTPS") -> FTPSClient(true)
            else -> FTPClient()
        }

        ftpClient?.apply {
            connectTimeout = 15000
            dataTimeout = Duration.ofMillis(15000)
            controlKeepAliveTimeout = 15L 
            controlKeepAliveReplyTimeout = 15000
            
            connect(host, port)
            val success = login(user, pass)
            
            if (!success) {
                disconnect()
                throw Exception("Invalid user name or password.")
            }

            enterLocalPassiveMode()
            setFileType(FTP.BINARY_FILE_TYPE)

            if (this is FTPSClient) {
                execPBSZ(0)
                execPROT("P")
            }
        }

        withContext(Dispatchers.Main) { result.success(null) }
    }

    private suspend fun handleList(path: String, result: MethodChannel.Result) {
        ftpClient?.changeWorkingDirectory(path)
        val files = ftpClient?.listFiles() ?: emptyArray()
        
        val list = files.map { file ->
            mapOf("name" to file.name, "isDir" to file.isDirectory, "size" to file.size)
        }
        withContext(Dispatchers.Main) { result.success(list) }
    }

    private suspend fun handleUpload(args: Map<String, Any>, result: MethodChannel.Result) {
        isTransferCancelled = false
        val localPath = args["localPath"] as? String ?: return
        val remotePath = args["remotePath"] as? String ?: return
        
        val localFile = File(localPath)
        setupProgressListener()

        FileInputStream(localFile).use { inputStream ->
            val success = ftpClient?.storeFile(remotePath, inputStream)
            if (isTransferCancelled) throw java.lang.Exception("CANCELLED")
            if (success != true) throw java.lang.Exception("Upload failed")
        }

        withContext(Dispatchers.Main) { result.success(null) }
    }

    private suspend fun handleDownload(args: Map<String, Any>, result: MethodChannel.Result) {
        isTransferCancelled = false
        val remotePath = args["remotePath"] as? String ?: return
        val localPath = args["localPath"] as? String ?: return
        
        val localFile = File(localPath)
        setupProgressListener()

        FileOutputStream(localFile).use { outputStream ->
            val success = ftpClient?.retrieveFile(remotePath, outputStream)
            if (isTransferCancelled) {
                localFile.delete() 
                throw java.lang.Exception("CANCELLED")
            }
            if (success != true) throw java.lang.Exception("Download failed")
        }

        withContext(Dispatchers.Main) { result.success(null) }
    }

    private fun setupProgressListener() {
        ftpClient?.setCopyStreamListener(object : CopyStreamAdapter() {
            private var lastReportTime = System.currentTimeMillis()

            override fun bytesTransferred(
                totalBytesTransferred: Long,
                bytesTransferred: Int,
                streamSize: Long
            ) {
                if (isTransferCancelled) {
                    throw RuntimeException("CANCELLED")
                }
                
                val now = System.currentTimeMillis()
                if (now - lastReportTime > 250 || totalBytesTransferred == streamSize) {
                    runOnUiThread {
                        methodChannel?.invokeMethod(
                            "progress", 
                            mapOf("transferred" to totalBytesTransferred, "total" to streamSize)
                        )
                    }
                    lastReportTime = now
                }
            }
        })
    }
}
