package xyz.vidur.pux.ui.screens

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlinx.coroutines.launch
import xyz.vidur.pux.service.DeliveryController
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.ui.dialogs.ConfirmServerDialog
import java.util.concurrent.Executors

@OptIn(ExperimentalGetImage::class)
@kotlin.OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EnrollScreen(
    onEnrolled: () -> Unit,
    onPasteFallback: () -> Unit,
    onBack: () -> Unit,
    initialCameraError: String? = null,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    val activity = context as? ComponentActivity

    var hasCameraPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        )
    }
    var cameraPermissionRequested by remember { mutableStateOf(false) }

    DisposableEffect(lifecycleOwner, context) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                hasCameraPermission = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }


    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasCameraPermission = granted
        cameraPermissionRequested = true
    }

    LaunchedEffect(Unit) {
        if (!hasCameraPermission) {
            permissionLauncher.launch(Manifest.permission.CAMERA)
            cameraPermissionRequested = true
        }
    }

    val cameraPermanentlyDenied = !hasCameraPermission &&
        cameraPermissionRequested &&
        activity != null &&
        !activity.shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)

    var processing by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var cameraError by remember { mutableStateOf<String?>(initialCameraError) }
    var pendingPayload by remember { mutableStateOf<Map<String, Any?>?>(null) }
    var pendingServerUrl by remember { mutableStateOf<String?>(null) }
    val cameraBinding = remember { CameraBinding() }
    val cameraScanningEnabled = pendingPayload == null && !processing && cameraError == null
    var cameraBindGeneration by remember { mutableIntStateOf(0) }

    LaunchedEffect(pendingPayload) {
        if (pendingPayload != null) {
            cameraBinding.pause()
        } else if (hasCameraPermission && cameraError == null) {
            cameraBinding.unpauseForRebind()
            cameraBindGeneration++
        }
    }

    val needsCameraPipeline = hasCameraPermission && cameraError == null
    val cameraExecutor = remember(needsCameraPipeline) {
        if (needsCameraPipeline) Executors.newSingleThreadExecutor() else null
    }
    val barcodeScanner = remember(needsCameraPipeline) {
        if (needsCameraPipeline) BarcodeScanning.getClient() else null
    }

    DisposableEffect(needsCameraPipeline) {
        onDispose {
            cameraBinding.close()
            barcodeScanner?.close()
            cameraExecutor?.shutdown()
        }
    }

    BackHandler(enabled = processing) {
        // Prevent back press while processing
    }

    fun proceedWithSave(payload: Map<String, Any?>) {
        processing = true
        errorMessage = null
        scope.launch {
            try {
                RecordStore.instance.saveEnrollment(payload)
                DeliveryController.instance.start()
                onEnrolled()
            } catch (e: Exception) {
                processing = false
                errorMessage = e.message ?: "Failed to save enrollment"
            }
        }
    }

    fun handleRawBarcode(raw: String) {
        if (processing || pendingPayload != null || cameraBinding.isPaused()) return
        try {
            val payload = RecordStore.instance.parseQr(raw)
            val server = RecordStore.instance.enrollmentServer(payload)
            pendingPayload = payload
            pendingServerUrl = server
        } catch (e: Exception) {
            errorMessage = e.message ?: "Invalid QR code"
        }
    }

    if (pendingPayload != null && pendingServerUrl != null) {
        ConfirmServerDialog(
            serverUrl = pendingServerUrl!!,
            onConfirm = {
                val payload = pendingPayload!!
                pendingPayload = null
                pendingServerUrl = null
                proceedWithSave(payload)
            },
            onDismiss = {
                pendingPayload = null
                pendingServerUrl = null
            }
        )
    }

    fun openAppSettings() {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null)
        )
        context.startActivity(intent)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Enroll device") },
                navigationIcon = {
                    if (!processing) {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    }
                }
            )
        },
        modifier = modifier
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            Text(
                text = "Scan the QR from an existing enrolled device.",
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                style = MaterialTheme.typography.bodyLarge
            )

            if (cameraError != null) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Icon(
                        imageVector = Icons.Default.Warning,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.error,
                        modifier = Modifier.size(48.dp)
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(
                        text = cameraError!!,
                        style = MaterialTheme.typography.bodyLarge,
                        textAlign = TextAlign.Center
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "You can enter your enrollment payload manually instead.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center
                    )
                    Spacer(modifier = Modifier.height(24.dp))
                    Button(
                        onClick = onPasteFallback,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Paste enrollment JSON instead")
                    }
                }
            } else if (hasCameraPermission) {
                if (cameraScanningEnabled) {
                key(cameraBindGeneration) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f)
                    ) {
                        AndroidView(
                            factory = { ctx ->
                                val previewView = PreviewView(ctx)
                                val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)

                                cameraProviderFuture.addListener({
                                    if (cameraBinding.isDisposed()) {
                                        return@addListener
                                    }
                                    try {
                                        val cameraProvider = cameraProviderFuture.get()
                                        if (cameraBinding.isDisposed()) {
                                            return@addListener
                                        }

                                        val preview = Preview.Builder().build().also {
                                            it.surfaceProvider = previewView.surfaceProvider
                                        }

                                        val imageAnalysis = ImageAnalysis.Builder()
                                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                            .build()

                                        val executor = requireNotNull(cameraExecutor)
                                        val scanner = requireNotNull(barcodeScanner)
                                        imageAnalysis.setAnalyzer(executor) { imageProxy ->
                                            if (cameraBinding.isDisposed() || cameraBinding.isPaused()) {
                                                imageProxy.close()
                                                return@setAnalyzer
                                            }
                                            val mediaImage = imageProxy.image
                                            if (mediaImage != null) {
                                                val image = InputImage.fromMediaImage(
                                                    mediaImage,
                                                    imageProxy.imageInfo.rotationDegrees
                                                )
                                                scanner.process(image)
                                                    .addOnSuccessListener { barcodes ->
                                                        if (cameraBinding.isDisposed() || cameraBinding.isPaused()) {
                                                            return@addOnSuccessListener
                                                        }
                                                        for (barcode in barcodes) {
                                                            if (barcode.valueType == Barcode.TYPE_TEXT ||
                                                                barcode.format == Barcode.FORMAT_QR_CODE
                                                            ) {
                                                                barcode.rawValue?.let { raw ->
                                                                    handleRawBarcode(raw)
                                                                }
                                                            }
                                                        }
                                                    }
                                                    .addOnCompleteListener {
                                                        imageProxy.close()
                                                    }
                                            } else {
                                                imageProxy.close()
                                            }
                                        }

                                        val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
                                        cameraBinding.bind(
                                            bind = { cameraProvider.bindToLifecycle(lifecycleOwner, cameraSelector, preview, imageAnalysis) },
                                            unbind = { cameraProvider.unbind(preview, imageAnalysis) }
                                        )
                                    } catch (e: Exception) {
                                        if (!cameraBinding.isDisposed()) {
                                            Log.w("EnrollScreen", "Failed to bind camera: ${e.message}", e)
                                            cameraError = "Camera unavailable: ${e.message ?: "could not bind back camera"}"
                                        }
                                    }
                                }, ContextCompat.getMainExecutor(ctx))

                                previewView
                            },
                            modifier = Modifier.fillMaxSize()
                        )
                    }
                }
                } else {
                    Spacer(modifier = Modifier.weight(1f))
                }
            } else {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Text(
                        text = if (cameraPermanentlyDenied) {
                            "Camera permission was denied. Open Settings to allow camera access, " +
                                "or enroll manually."
                        } else {
                            "Camera permission is required to scan QR codes."
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        textAlign = TextAlign.Center
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                    if (cameraPermanentlyDenied) {
                        Button(
                            onClick = { openAppSettings() },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Open Settings")
                        }
                        Spacer(modifier = Modifier.height(8.dp))
                        OutlinedButton(
                            onClick = onPasteFallback,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Paste enrollment JSON instead")
                        }
                    } else {
                        Button(onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) }) {
                            Text("Grant camera permission")
                        }
                    }
                }
            }

            if (processing) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }

            if (errorMessage != null) {
                Text(
                    text = errorMessage!!,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(16.dp),
                    style = MaterialTheme.typography.bodyMedium
                )
            }

            OutlinedButton(
                onClick = onPasteFallback,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp)
            ) {
                Text("Paste enrollment JSON instead")
            }
        }
    }
}
