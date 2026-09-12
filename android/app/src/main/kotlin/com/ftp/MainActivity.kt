package com.ftp

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import org.apache.commons.net.ftp.FTPSClient
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import kotlin.concurrent.thread

class MainActivity: FlutterActivity() {
    private val CHANNEL = "ftp_native"
    private var ftpClient: FTPClient? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var isCancelled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<String, Any>
            thread {
                try {
                    when (call.method) {
                        "connect" -> {
                            val mode = args?.get("mode") as? String ?: "FTP"
                            val host = args?.get("host") as? String ?: ""
                            val port = args?.get("port") as? Int ?: 21
                            val user = args?.get("user") as? String ?: ""
                            val pass = args?.get("pass") as? String ?: ""

                            ftpClient = when {
                                mode.contains("FTPES") -> FTPSClient(false)
                                mode.contains("FTPS") -> FTPSClient(true)
                                else -> FTPClient()
                            }
                            
                            // Dosya aktarımı sırasında kontrol bağlantısının kopmasını engellemek için
                            ftpClient?.controlKeepAliveTimeout = 15
                            ftpClient?.controlKeepAliveReplyTimeout = 15000
                            
                            ftpClient?.connect(host, port)
                            val success = ftpClient?.login(user, pass) ?: false
                            if (!success) throw Exception("Invalid user name or password.")

                            ftpClient?.enterLocalPassiveMode()
                            ftpClient?.setFileType(FTP.BINARY_FILE_TYPE)

                            if (ftpClient is FTPSClient) {
                                (ftpClient as FTPSClient).execPBSZ(0)
                                (ftpClient as FTPSClient).execPROT("P")
                            }
                            mainHandler.post { result.success(true) }
                        }
                        "noop" -> {
                            // Arka planda sunucu bağlantısını canlı tutmak için (Ping)
                            // Ölü bağlantıda Broken pipe hatası verirse yutulur
                            val success = try { ftpClient?.sendNoOp() ?: false } catch (e: Exception) { false }
                            mainHandler.post { result.success(success) }
                        }
                        "disconnect" -> {
                            // Eski ölü bağlantıyı kapatırken hata verirse (Broken pipe vs.) sistemi çökertmemesi için yutulur
                            try {
                                if (ftpClient?.isConnected == true) {
                                    try { ftpClient?.logout() } catch (e: Exception) {}
                                    try { ftpClient?.disconnect() } catch (e: Exception) {}
                                }
                            } catch (e: Exception) {}
                            mainHandler.post { result.success(true) }
                        }
                        "cancel" -> {
                            isCancelled = true
                            mainHandler.post { result.success(true) }
                        }
                        "list" -> {
                            val path = args?.get("path") as? String ?: "/"
                            ftpClient?.changeWorkingDirectory(path)
                            val files = ftpClient?.listFiles() ?: emptyArray()
                            val list = files.map {
                                mapOf("name" to it.name, "isDir" to it.isDirectory, "size" to it.size)
                            }
                            mainHandler.post { result.success(list) }
                        }
                        "cd" -> {
                            val path = args?.get("path") as? String ?: "/"
                            val success = ftpClient?.changeWorkingDirectory(path) ?: false
                            if(!success) throw Exception("Path not found")
                            mainHandler.post { result.success(true) }
                        }
                        "mkdir" -> {
                            val name = args?.get("name") as? String ?: ""
                            val success = ftpClient?.makeDirectory(name) ?: false
                            if(!success) throw Exception("Could not create directory")
                            mainHandler.post { result.success(true) }
                        }
                        "rename" -> {
                            val old = args?.get("old") as? String ?: ""
                            val new = args?.get("new") as? String ?: ""
                            val success = ftpClient?.rename(old, new) ?: false
                            if(!success) throw Exception("Rename failed")
                            mainHandler.post { result.success(true) }
                        }
                        "delete" -> {
                            val name = args?.get("name") as? String ?: ""
                            val isDir = args?.get("isDir") as? Boolean ?: false
                            val success = if (isDir) ftpClient?.removeDirectory(name) else ftpClient?.deleteFile(name)
                            if (success != true) throw Exception("Delete failed")
                            mainHandler.post { result.success(true) }
                        }
                        "upload" -> {
                            isCancelled = false
                            val localPath = args?.get("localPath") as? String ?: ""
                            val remotePath = args?.get("remotePath") as? String ?: ""
                            val file = File(localPath)
                            val totalSize = file.length()
                            val fis = FileInputStream(file)

                            val outputStream = ftpClient?.storeFileStream(remotePath)
                            if (outputStream == null) {
                                fis.close()
                                throw Exception("Stream error: ${ftpClient?.replyString}")
                            }
                            
                            val buffer = ByteArray(32 * 1024)
                            var bytesRead: Int
                            var uploadedSize = 0L
                            var lastReportTime = System.currentTimeMillis()
                            
                            try {
                                while (fis.read(buffer).also { bytesRead = it } != -1) {
                                    if (isCancelled) throw Exception("CANCELLED")
                                    outputStream.write(buffer, 0, bytesRead)
                                    uploadedSize += bytesRead
                                    
                                    val now = System.currentTimeMillis()
                                    if (now - lastReportTime > 250 || uploadedSize == totalSize) {
                                        mainHandler.post {
                                            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                                                .invokeMethod("progress", mapOf("transferred" to uploadedSize, "total" to totalSize))
                                        }
                                        lastReportTime = now
                                    }
                                }
                            } finally {
                                try { outputStream.close() } catch(e: Exception) {}
                                try { fis.close() } catch(e: Exception) {}
                            }
                            
                            val success = ftpClient?.completePendingCommand() ?: false
                            if (!success && !isCancelled) throw Exception("Upload failed: ${ftpClient?.replyString}")
                            
                            mainHandler.post { result.success(true) }
                        }
                        "download" -> {
                            isCancelled = false
                            val remotePath = args?.get("remotePath") as? String ?: ""
                            val localPath = args?.get("localPath") as? String ?: ""
                            val file = File(localPath)
                            
                            ftpClient?.sendCommand("SIZE", remotePath)
                            val reply = ftpClient?.replyString ?: ""
                            var totalSize = 0L
                            if (reply.startsWith("213")) {
                                totalSize = reply.substring(4).trim().toLongOrNull() ?: 0L
                            }

                            val fos = FileOutputStream(file)
                            val inputStream = ftpClient?.retrieveFileStream(remotePath)
                            if (inputStream == null) {
                                fos.close()
                                throw Exception("Stream error: ${ftpClient?.replyString}")
                            }
                            
                            val buffer = ByteArray(32 * 1024)
                            var bytesRead: Int
                            var downloadedSize = 0L
                            var lastReportTime = System.currentTimeMillis()
                            
                            try {
                                while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                                    if (isCancelled) throw Exception("CANCELLED")
                                    fos.write(buffer, 0, bytesRead)
                                    downloadedSize += bytesRead
                                    
                                    val now = System.currentTimeMillis()
                                    if (now - lastReportTime > 250 || downloadedSize == totalSize) {
                                        mainHandler.post {
                                            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                                                .invokeMethod("progress", mapOf("transferred" to downloadedSize, "total" to totalSize))
                                        }
                                        lastReportTime = now
                                    }
                                }
                            } finally {
                                try { inputStream.close() } catch(e: Exception) {}
                                try { fos.close() } catch(e: Exception) {}
                            }
                            
                            val success = ftpClient?.completePendingCommand() ?: false
                            if (!success && !isCancelled) throw Exception("Download failed: ${ftpClient?.replyString}")
                            
                            mainHandler.post { result.success(true) }
                        }
                        else -> mainHandler.post { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    val msg = e.message ?: "Unknown error"
                    mainHandler.post { 
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
}
