package xyz.vidur.pux

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.launch
import xyz.vidur.pux.model.NotificationAccess
import xyz.vidur.pux.push.SensitiveClipboard
import xyz.vidur.pux.service.DeliveryController
import xyz.vidur.pux.service.RemovalState
import xyz.vidur.pux.storage.FlutterSecureStorageMigrator
import xyz.vidur.pux.storage.RecordStore
import xyz.vidur.pux.storage.RecordStoreWrite
import xyz.vidur.pux.storage.RemovalNoticeStore
import xyz.vidur.pux.service.CreateRelayState
import xyz.vidur.pux.system.AppDataReset
import xyz.vidur.pux.system.NotificationPermissions
import xyz.vidur.pux.ui.dialogs.NotificationExplainerDialog
import xyz.vidur.pux.ui.screens.CreateRelayScreen
import xyz.vidur.pux.ui.screens.EnrollChooserScreen
import xyz.vidur.pux.ui.screens.EnrollScreen
import xyz.vidur.pux.ui.screens.ForwardingHelpScreen
import xyz.vidur.pux.ui.screens.HomeScreen
import xyz.vidur.pux.ui.screens.ImportEnrollmentScreen
import xyz.vidur.pux.ui.theme.PuxTheme

sealed class AppScreen {
    data object Chooser : AppScreen()
    data object CreateRelay : AppScreen()
    data object Enroll : AppScreen()
    data object Import : AppScreen()
    data object Home : AppScreen()
    data class ForwardingHelp(val inbox: String?) : AppScreen()
}

private fun screenToKey(screen: AppScreen): String = when (screen) {
    is AppScreen.Chooser -> "chooser"
    is AppScreen.CreateRelay -> "create_relay"
    is AppScreen.Enroll -> "enroll"
    is AppScreen.Import -> "import"
    is AppScreen.Home -> "home"
    is AppScreen.ForwardingHelp -> "forwarding_help:${screen.inbox ?: ""}"
}

private fun keyToScreen(key: String): AppScreen = when {
    key == "chooser" -> AppScreen.Chooser
    key == "create_relay" -> AppScreen.CreateRelay
    key == "enroll" -> AppScreen.Enroll
    key == "import" -> AppScreen.Import
    key == "home" -> AppScreen.Home
    key.startsWith("forwarding_help:") -> {
        val inbox = key.removePrefix("forwarding_help:").ifEmpty { null }
        AppScreen.ForwardingHelp(inbox)
    }
    else -> AppScreen.Chooser
}

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            PuxTheme {
                PuxApp(activity = this)
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        SensitiveClipboard.instance.onWindowFocusChanged(hasFocus)
    }
}

@Composable
fun PuxApp(activity: ComponentActivity) {
    val scope = rememberCoroutineScope()
    val lifecycleOwner = LocalLifecycleOwner.current
    val app = activity.application as PuxApplication

    // Saved backstack navigation with system Back support and state restoration across rotation
    val backStack = rememberSaveable(
        saver = listSaver(
            save = { it.map { screen -> screenToKey(screen) } },
            restore = { restored ->
                val list = mutableStateListOf<AppScreen>()
                list.addAll(restored.map { keyToScreen(it) })
                if (list.isEmpty()) {
                    list.add(if (RecordStore.instance.isEnrolled()) AppScreen.Home else AppScreen.Chooser)
                }
                list
            }
        )
    ) {
        mutableStateListOf(if (RecordStore.instance.isEnrolled()) AppScreen.Home else AppScreen.Chooser)
    }

    val removalState by app.removalController.state.collectAsState()
    var showRemovalNotice by remember {
        mutableStateOf(RemovalNoticeStore.peek(activity.applicationContext) != null)
    }
    LaunchedEffect(removalState) {
        when (val state = removalState) {
            is RemovalState.Completed -> {
                if (app.forgetBlocksSetup()) return@LaunchedEffect
                backStack.clear()
                backStack.add(AppScreen.Chooser)
                if (state.staleRegistrationNotice != null) {
                    showRemovalNotice = true
                } else if (RemovalNoticeStore.peek(activity.applicationContext) == null) {
                    app.removalController.acknowledgeCompletion()
                }
            }
            RemovalState.Idle -> {
                if (
                    !app.forgetBlocksSetup() &&
                    !RecordStore.instance.isEnrolled() &&
                    backStack.any { it is AppScreen.Home }
                ) {
                    backStack.clear()
                    backStack.add(AppScreen.Chooser)
                }
            }
            else -> Unit
        }
    }
    val migrationBlocksSetup = app.migrationBlocksSetup()
    val forgetBlocksSetup = app.forgetBlocksSetup()
    val setupBlocked = migrationBlocksSetup || forgetBlocksSetup
    val currentScreen = when {
        forgetBlocksSetup -> AppScreen.Home
        removalState is RemovalState.Completed -> AppScreen.Chooser
        removalState == RemovalState.Running || removalState is RemovalState.Failed -> AppScreen.Home
        RecordStore.instance.pendingRemoteRemoval() != null -> AppScreen.Home
        else -> backStack.lastOrNull() ?: AppScreen.Chooser
    }

    // Handle system back press
    BackHandler(enabled = backStack.size > 1) {
        backStack.removeAt(backStack.size - 1)
    }

    var showNotificationExplainer by remember { mutableStateOf(false) }
    var resumeCounter by remember { mutableIntStateOf(0) }
    val migrationResult by app.migrationResultState.collectAsState()
    val legacyCleanupPending = FlutterSecureStorageMigrator.isLegacyCleanupPending(activity)
    val showMigrationNotice = migrationResult is FlutterSecureStorageMigrator.MigrationResult.Failed ||
        legacyCleanupPending
    val snackbarHostState = remember { SnackbarHostState() }
    val storageErrorText = stringResource(R.string.error_storage_preference_not_saved)
    var showMigrationDiscardConfirm by remember { mutableStateOf(false) }
    var showKeystoreResetConfirm by remember { mutableStateOf(false) }

    val createRelayState by app.createRelayController.state.collectAsState()
    LaunchedEffect(createRelayState) {
        if (createRelayState == CreateRelayState.Completed) {
            backStack.clear()
            backStack.add(AppScreen.Home)
            app.createRelayController.acknowledgeCompletion()
        }
    }

    // Refresh delivery and prompt checks whenever returning from settings / foregrounding
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                if (
                    RecordStore.instance.isEnrolled() &&
                    !app.forgetBlocksSetup() &&
                    app.keystoreError == null
                ) {
                    DeliveryController.instance.onResume()
                }
                resumeCounter++
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) {
        scope.launch {
            if (RecordStoreWrite.run { RecordStore.instance.saveNotificationPermissionAsked() }) {
                resumeCounter++
            } else {
                snackbarHostState.showSnackbar(storageErrorText)
            }
        }
    }

    fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    LaunchedEffect(currentScreen, resumeCounter) {
        if (currentScreen is AppScreen.Home && !forgetBlocksSetup && app.keystoreError == null) {
            DeliveryController.instance.start()
            val skipped = RecordStore.instance.notificationExplainerSkipped()
            val access = NotificationPermissions.check(activity, RecordStore.instance)
            if (!skipped && access == NotificationAccess.NOT_ASKED) {
                showNotificationExplainer = true
            }
        }
    }

    if (showKeystoreResetConfirm) {
        AlertDialog(
            onDismissRequest = { showKeystoreResetConfirm = false },
            title = { Text(stringResource(R.string.dialog_reset_storage_title)) },
            text = { Text(stringResource(R.string.dialog_reset_storage_body)) },
            confirmButton = {
                Button(onClick = { AppDataReset.resetAndRestart(activity) }) {
                    Text(stringResource(R.string.action_reset))
                }
            },
            dismissButton = {
                TextButton(onClick = { showKeystoreResetConfirm = false }) {
                    Text(stringResource(R.string.action_cancel))
                }
            }
        )
    }

    // Fail-closed Keystore error dialog
    if (app.keystoreError != null) {
        AlertDialog(
            onDismissRequest = { /* Non-dismissible on fatal Keystore error */ },
            title = { Text(stringResource(R.string.dialog_keystore_error_title)) },
            text = {
                Text(stringResource(R.string.dialog_keystore_error_body, app.keystoreError?.message ?: ""))
            },
            confirmButton = {
                Button(onClick = { activity.finish() }) {
                    Text(stringResource(R.string.action_exit))
                }
            },
            dismissButton = {
                TextButton(onClick = { showKeystoreResetConfirm = true }) {
                    Text(stringResource(R.string.action_reset_local_storage))
                }
            }
        )
        return
    }

    val removalNoticeText = RemovalNoticeStore.peek(activity.applicationContext)
        ?: (removalState as? RemovalState.Completed)?.staleRegistrationNotice
    if (showRemovalNotice && removalNoticeText != null) {
        AlertDialog(
            onDismissRequest = { },
            title = { Text(stringResource(R.string.dialog_removal_notice_title)) },
            text = { Text(removalNoticeText) },
            confirmButton = {
                Button(
                    onClick = {
                        RemovalNoticeStore.clear(activity.applicationContext)
                        showRemovalNotice = false
                        app.removalController.acknowledgeCompletion()
                    }
                ) {
                    Text(stringResource(R.string.action_ok))
                }
            }
        )
    }

    if (showMigrationDiscardConfirm) {
        AlertDialog(
            onDismissRequest = { showMigrationDiscardConfirm = false },
            title = { Text(stringResource(R.string.dialog_discard_migration_title)) },
            text = { Text(stringResource(R.string.dialog_discard_migration_body)) },
            confirmButton = {
                Button(
                    onClick = {
                        app.discardFailedMigration()
                        showMigrationDiscardConfirm = false
                    }
                ) {
                    Text(stringResource(R.string.action_discard))
                }
            },
            dismissButton = {
                TextButton(onClick = { showMigrationDiscardConfirm = false }) {
                    Text(stringResource(R.string.action_cancel))
                }
            }
        )
    }

    // Inform user if Flutter secure storage could not be migrated
    if (showMigrationNotice) {
        val failResult = app.migrationResult as? FlutterSecureStorageMigrator.MigrationResult.Failed
        AlertDialog(
            onDismissRequest = { },
            title = { Text(stringResource(R.string.dialog_migration_recovery_title)) },
            text = {
                Text(
                    if (legacyCleanupPending && failResult == null) {
                        stringResource(R.string.dialog_migration_cleanup_pending_body)
                    } else {
                        stringResource(R.string.dialog_migration_recovery_body, failResult?.reason ?: "")
                    }
                )
            },
            confirmButton = {
                Button(onClick = {
                    val recovered = app.retryFlutterMigration()
                    if (recovered && RecordStore.instance.isEnrolled()) {
                        backStack.clear()
                        backStack.add(AppScreen.Home)
                    }
                }) {
                    Text(stringResource(R.string.action_try_again))
                }
            },
            dismissButton = {
                TextButton(onClick = { showMigrationDiscardConfirm = true }) {
                    Text(stringResource(R.string.action_discard_previous_data))
                }
            }
        )
    }

    if (showNotificationExplainer) {
        NotificationExplainerDialog(
            onContinue = {
                showNotificationExplainer = false
                requestNotificationPermission()
            },
            onNotNow = {
                showNotificationExplainer = false
                if (!RecordStoreWrite.run { RecordStore.instance.saveNotificationExplainerSkipped() }) {
                    scope.launch { snackbarHostState.showSnackbar(storageErrorText) }
                }
            }
        )
    }

    Box(modifier = Modifier.fillMaxSize()) {
    when (val screen = currentScreen) {
        is AppScreen.Chooser -> {
            EnrollChooserScreen(
                onCreateRelay = {
                    if (!setupBlocked) backStack.add(AppScreen.CreateRelay)
                },
                onAddToRelay = {
                    if (!setupBlocked) backStack.add(AppScreen.Enroll)
                },
                migrationRecoveryRequired = setupBlocked,
                forgetCleanupRequired = forgetBlocksSetup
            )
        }
        is AppScreen.CreateRelay -> {
            CreateRelayScreen(
                controller = app.createRelayController,
                onBack = {
                    if (backStack.size > 1) backStack.removeAt(backStack.size - 1)
                }
            )
        }
        is AppScreen.Enroll -> {
            EnrollScreen(
                onEnrolled = {
                    backStack.clear()
                    backStack.add(AppScreen.Home)
                },
                onPasteFallback = {
                    backStack.removeAt(backStack.size - 1)
                    backStack.add(AppScreen.Import)
                },
                onBack = {
                    if (backStack.size > 1) backStack.removeAt(backStack.size - 1)
                }
            )
        }
        is AppScreen.Import -> {
            ImportEnrollmentScreen(
                onEnrolled = {
                    backStack.clear()
                    backStack.add(AppScreen.Home)
                },
                onBack = {
                    if (backStack.size > 1) backStack.removeAt(backStack.size - 1)
                }
            )
        }
        is AppScreen.Home -> {
            HomeScreen(
                onNavigateToForwardingHelp = { inbox ->
                    backStack.add(AppScreen.ForwardingHelp(inbox))
                },
                onAskNotification = { requestNotificationPermission() },
                refreshTrigger = resumeCounter
            )
        }
        is AppScreen.ForwardingHelp -> {
            ForwardingHelpScreen(
                inbox = screen.inbox,
                onBack = {
                    if (backStack.size > 1) backStack.removeAt(backStack.size - 1)
                }
            )
        }
    }
        SnackbarHost(
            hostState = snackbarHostState,
            modifier = Modifier.align(Alignment.BottomCenter)
        )
    }
}
