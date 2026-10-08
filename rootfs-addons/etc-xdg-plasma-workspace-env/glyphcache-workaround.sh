# Qt glyph cache: keep a CPU-side copy and re-upload it instead of copying
# the atlas texture on the GPU when it grows. Testing whether the GPU-side
# copy on panfrost / Mali-G71 r0p0 is what drops letters in Plasma labels
# ("i-Fi", "Mobi e Data") until the session restarts.
export QML_USE_GLYPHCACHE_WORKAROUND=1
export QT_ENABLE_GLYPH_CACHE_WORKAROUND=1
