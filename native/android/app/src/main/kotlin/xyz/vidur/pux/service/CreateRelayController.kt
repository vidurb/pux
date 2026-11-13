package xyz.vidur.pux.service

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import xyz.vidur.pux.api.ApiClient
import xyz.vidur.pux.crypto.PuxCrypto
import xyz.vidur.pux.storage.RecordStore

sealed interface CreateRelayState {
    data object Idle : CreateRelayState
    data object Running : CreateRelayState
    data class Failed(val message: String) : CreateRelayState
    data object Completed : CreateRelayState
}

/** Application-owned create-relay work survives Activity recreation. */
class CreateRelayController(
    private val store: RecordStore,
    private val api: ApiClient,
    private val delivery: DeliveryController,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
) {
    private val _state = MutableStateFlow<CreateRelayState>(CreateRelayState.Idle)
    val state = _state.asStateFlow()

    @Synchronized
    fun start() {
        if (_state.value == CreateRelayState.Running || _state.value == CreateRelayState.Completed) return
        _state.value = CreateRelayState.Running
        scope.launch {
            try {
                val keyPair = PuxCrypto.generateKeyPair()
                val record = api.createRecord(keyPair.publicKeyB64)

                try {
                    store.saveEnrollment(
                        mapOf(
                            "record_id" to record.recordId,
                            "private_key" to keyPair.privateKeyB64,
                            "public_key" to keyPair.publicKeyB64,
                            "inbox" to record.inboxAddress,
                            "server" to store.serverUrl
                        )
                    )
                } catch (saveError: Exception) {
                    try {
                        api.deleteRecord(record.recordId)
                    } catch (_: Exception) {
                        // Ignore deletion failure of unsaved record
                    }
                    throw saveError
                }

                delivery.start()
                _state.value = CreateRelayState.Completed
            } catch (e: Exception) {
                _state.value = CreateRelayState.Failed(e.message ?: "Failed to create relay")
            }
        }
    }

    @Synchronized
    fun acknowledgeCompletion() {
        if (_state.value == CreateRelayState.Completed) {
            _state.value = CreateRelayState.Idle
        }
    }

    @Synchronized
    fun clearFailure() {
        if (_state.value is CreateRelayState.Failed) {
            _state.value = CreateRelayState.Idle
        }
    }
}
