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

                            // Hızlandırma ve bağlantı kopmasını engelleme (53MB+ büyük dosyalar için)
                            ftpClient?.controlKeepAliveTimeout = 300 // 5 Dakika
                            ftpClient?.controlKeepAliveReplyTimeout = 300
                            
                            ftpClient?.connect(host, port)
                            val success = ftpClient?.login(user, pass) ?: false
                            if (!success) throw Exception("Invalid user name or password.")

                            ftpClient?.enterLocalPassiveMode()
                            ftpClient?.setFileType(FTP.BINARY_FILE_TYPE)
                            
                            // 1MB Buffer ile arşa çıkan hız ve modern I/O
                            ftpClient?.bufferSize = 1024 * 1024 
                            ftpClient?.isUseEPSVwithIPv4 = true 

                            if (ftpClient is FTPSClient) {
                                (ftpClient as FTPSClient).execPBSZ(0)
                                (ftpClient as FTPSClient).execPROT("P")
                            }
                            mainHandler.post { result.success(true) }
                        }
                        "disconnect" -> {
                            if (ftpClient?.isConnected == true) {
                                ftpClient?.logout()
                                ftpClient?.disconnect()
                            }
                            mainHandler.post { result.success(true) }
                        }
                        "cancel" -> {
                            isCancelled = true // Transfer döngüsünü durdurur
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
                            
                            // Parçalı veri gönderimi (Progress Callback ve hız limitini kaldırma için)
                            val outputStream = ftpClient?.storeFileStream(remotePath)
                            if (outputStream == null) throw Exception("Upload stream is null")
                            
                            val buffer = ByteArray(1024 * 1024) // 1MB Chunk size
                            var bytesRead: Int
                            var uploadedSize = 0L
                            var lastReportTime = System.currentTimeMillis()
                            
                            while (fis.read(buffer).also { bytesRead = it } != -1) {
                                if (isCancelled) break
                                outputStream.write(buffer, 0, bytesRead)
                                uploadedSize += bytesRead
                                val now = System.currentTimeMillis()
                                if (now - lastReportTime > 500 || uploadedSize == totalSize) { // Yarım saniyede bir UI güncellemesi
                                    mainHandler.post {
                                        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                                            .invokeMethod("progress", mapOf("transferred" to uploadedSize, "total" to totalSize))
                                    }
                                    lastReportTime = now
                                }
                            }
                            outputStream.close()
                            fis.close()
                            val success = ftpClient?.completePendingCommand() ?: false
                            if(!success && !isCancelled) throw Exception("Upload failed on completion")
                            mainHandler.post { result.success(true) }
                        }
                        "download" -> {
                            isCancelled = false
                            val remotePath = args?.get("remotePath") as? String ?: ""
                            val localPath = args?.get("localPath") as? String ?: ""
                            val file = File(localPath)
                            
                            // Toplam boyutu öğren (Arayüzde % hesaplayabilmek için)
                            ftpClient?.sendCommand("SIZE", remotePath)
                            val reply = ftpClient?.replyString ?: ""
                            var totalSize = 0L
                            if (reply.startsWith("213")) {
                                totalSize = reply.substring(4).trim().toLongOrNull() ?: 0L
                            }

                            val fos = FileOutputStream(file)
                            val inputStream = ftpClient?.retrieveFileStream(remotePath)
                            if (inputStream == null) throw Exception("Download stream is null")
                            
                            val buffer = ByteArray(1024 * 1024) // 1MB chunk size
                            var bytesRead: Int
                            var downloadedSize = 0L
                            var lastReportTime = System.currentTimeMillis()
                            
                            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                                if (isCancelled) break
                                fos.write(buffer, 0, bytesRead)
                                downloadedSize += bytesRead
                                val now = System.currentTimeMillis()
                                if (now - lastReportTime > 500 || downloadedSize == totalSize) {
                                    mainHandler.post {
                                        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                                            .invokeMethod("progress", mapOf("transferred" to downloadedSize, "total" to totalSize))
                                    }
                                    lastReportTime = now
                                }
                            }
                            inputStream.close()
                            fos.close()
                            val success = ftpClient?.completePendingCommand() ?: false
                            if(!success && !isCancelled) throw Exception("Download failed on completion")
                            mainHandler.post { result.success(true) }
                        }
                        else -> mainHandler.post { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    mainHandler.post { result.error("FTP_ERR", e.message, null) }
                }
            }
        }
    }
}
