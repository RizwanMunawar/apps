import CoreImage

/// One `CIContext` for the whole app.
///
/// A CIContext carries its own GPU command queue, texture cache and intermediate buffer pool, so
/// each one costs real memory. The detector, the live pipeline and the file encoder used to build
/// their own, which meant three of everything alive at once; they all share this instead.
///
/// `cacheIntermediates` is off because nothing here re-renders the same graph twice: every frame
/// is new, so caching intermediates only grows the footprint over a long export without ever
/// being read back.
enum RenderContext {
    static let shared = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
    ])
}
