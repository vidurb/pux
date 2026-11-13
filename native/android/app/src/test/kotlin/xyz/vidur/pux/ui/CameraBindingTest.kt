package xyz.vidur.pux.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraBindingTest {
    @Test fun leavingScannerUnbindsOnlyOnce() {
        val binding = CameraBinding()
        var bound = 0
        var unbound = 0
        binding.bind({ bound++ }, { unbound++ })
        binding.close()
        binding.close()
        assertEquals(1, bound)
        assertEquals(1, unbound)
    }

    @Test fun providerCallbackAfterLeavingDoesNotBind() {
        val binding = CameraBinding()
        var bound = 0
        var unbound = 0
        binding.close()
        binding.bind({ bound++ }, { unbound++ })
        assertEquals(0, bound)
        assertEquals(0, unbound)
    }

    @Test fun failedBindCleansUpUseCases() {
        val binding = CameraBinding()
        var unbound = 0
        try { binding.bind({ throw IllegalStateException() }, { unbound++ }) } catch (_: IllegalStateException) { }
        binding.close()
        assertEquals(1, unbound)
    }

    @Test fun unpauseForRebindAllowsBindingAfterPause() {
        val binding = CameraBinding()
        var bound = 0
        binding.bind({ bound++ }, {})
        binding.pause()
        binding.bind({ bound++ }, {})
        assertEquals(1, bound)
        binding.unpauseForRebind()
        binding.bind({ bound++ }, {})
        assertEquals(2, bound)
        binding.close()
    }

    @Test fun pauseStopsBindingUntilResume() {
        val binding = CameraBinding()
        var bound = 0
        var unbound = 0
        binding.bind({ bound++ }, { unbound++ })
        binding.pause()
        assertEquals(1, unbound)
        binding.bind({ bound++ }, { unbound++ })
        assertEquals(1, bound)
        binding.resume({ bound++ }, { unbound++ })
        assertEquals(2, bound)
        binding.close()
    }
}
