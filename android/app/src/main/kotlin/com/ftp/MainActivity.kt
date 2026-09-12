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

                            // Uyumsuzluk çıkaran timeout satırları kaldırıldı, standart güvenli bağlantıya geçildi
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
                        "disconnect" -> {
                            if (ftpClient?.isConnected == true) {
                                ftpClient?.logout()
                                ftpClient?.disconnect()
                            }
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
                            val localPath = args?.get("localPath") as? String ?: ""
                            val remotePath = args?.get("remotePath") as? String ?: ""
                            val file = File(localPath)
                            val fis = FileInputStream(file)
                            val success = ftpClient?.storeFile(remotePath, fis) ?: false
                            fis.close()
                            if(!success) throw Exception("Upload failed")
                            mainHandler.post { result.success(true) }
                        }
                        "download" -> {
                            val remotePath = args?.get("remotePath") as? String ?: ""
                            val localPath = args?.get("localPath") as? String ?: ""
                            val file = File(localPath)
                            val fos = FileOutputStream(file)
                            val success = ftpClient?.retrieveFile(remotePath, fos) ?: false
                            fos.close()
                            if(!success) throw Exception("Download failed")
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
