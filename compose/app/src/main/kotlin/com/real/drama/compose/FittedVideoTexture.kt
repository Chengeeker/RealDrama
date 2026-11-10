package com.real.drama.compose

import android.content.Context
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.view.TextureView

internal fun fittedTextureScale(width: Float, height: Float, aspect: Float): Pair<Float, Float> {
    if (width <= 0 || height <= 0 || !aspect.isFinite() || aspect <= 0) return 1f to 1f
    val videoWidth = minOf(width, height * aspect)
    val videoHeight = videoWidth / aspect
    val bufferVideoWidth = minOf(1f, aspect)
    val bufferVideoHeight = bufferVideoWidth / aspect
    return videoWidth / (width * bufferVideoWidth) to videoHeight / (height * bufferVideoHeight)
}

internal class FittedVideoTexture(
    context: Context, player: MpvPlayer, private val onFrameReady: ((Boolean) -> Unit)? = null,
) : TextureView(context) {
    internal val renderSide = maxOf(resources.displayMetrics.widthPixels, resources.displayMetrics.heightPixels).coerceIn(1, player.renderLimit)
    private var aspect = 0f
    private var currentSurface: SurfaceTexture? = null
    private var restoreBuffer = false
    private var initialTimestamp = 0L
    private var frameReady = false
    private var pendingFrameCheck: SurfaceTexture? = null
    private val fit = Matrix()
    init {
        alpha = 0f
        surfaceTextureListener = object : SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                currentSurface = surface
                resetFrame(surface)
                surface.setDefaultBufferSize(renderSide, renderSide)
                player.attach(surface, renderSide, renderSide)
                fitVideo()
            }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
                if (surface !== currentSurface || surface.isReleased) return
                surface.setDefaultBufferSize(renderSide, renderSide)
                fitVideo()
            }
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {
                if (restoreBuffer && surface === currentSurface && !surface.isReleased) {
                    restoreBuffer = false
                    surface.setDefaultBufferSize(renderSide, renderSide)
                    fitVideo()
                }
                if (surface === currentSurface && pendingFrameCheck !== surface) checkFrame(surface, remaining = 2)
            }
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                if (currentSurface === surface) {
                    currentSurface = null
                    resetFrame(null)
                }
                player.detach(surface)
                return false
            }
        }
    }
    fun setVideoAspect(value: Float) {
        if (aspect == value) return
        if (aspect > 0f && (!value.isFinite() || value <= 0f)) resetFrame(currentSurface)
        aspect = value
        alpha = if (value.isFinite() && value > 0) 1f else 0f
        fitVideo()
        currentSurface?.let { checkFrame(it, remaining = 0) }
    }
    private fun resetFrame(surface: SurfaceTexture?) {
        if (onFrameReady == null) return
        pendingFrameCheck = null
        initialTimestamp = if (surface != null && !surface.isReleased) surface.timestamp else 0L
        if (frameReady) {
            frameReady = false
            onFrameReady(false)
        }
    }
    private fun checkFrame(surface: SurfaceTexture, remaining: Int) {
        if (onFrameReady == null || frameReady || !aspect.isFinite() || aspect <= 0f || surface !== currentSurface || surface.isReleased) return
        if (surface.timestamp != initialTimestamp) {
            frameReady = true
            onFrameReady(true)
        } else if (remaining > 0) {
            pendingFrameCheck = surface
            postOnAnimation {
                if (pendingFrameCheck !== surface) return@postOnAnimation
                pendingFrameCheck = null
                checkFrame(surface, remaining - 1)
            }
        }
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        fitVideo()
    }
    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility == VISIBLE) restoreBuffer = true
    }
    private fun fitVideo() {
        val (x, y) = fittedTextureScale(width.toFloat(), height.toFloat(), aspect)
        fit.setScale(x, y, width / 2f, height / 2f)
        setTransform(fit)
    }
}
