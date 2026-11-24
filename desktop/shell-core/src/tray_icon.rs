//! The menu-bar glyph, drawn at startup instead of shipped as an asset.
//!
//! macOS menu-bar icons are *template images*: black pixels whose alpha is the
//! shape, which the system tints for light/dark mode and the highlighted state.
//! A ring with a centre dot ("an arbiter's eye") needs no artwork, and drawing
//! it here keeps the Tauri crate free of an image-decoding feature.

/// Side of the glyph in pixels; 44 is a 22 pt menu-bar icon at @2x.
pub const SIZE: u32 = 44;

/// `size`×`size` RGBA, every colour channel 0 (black), alpha the shape.
pub fn template_rgba(size: u32) -> Vec<u8> {
    let c = (size as f32 - 1.0) / 2.0;
    let scale = size as f32 / SIZE as f32;
    let (ring_r, dot_r, edge) = (17.0 * scale, 6.5 * scale, 1.5);
    let mut out = Vec::with_capacity((size * size * 4) as usize);
    for y in 0..size {
        for x in 0..size {
            let d = ((x as f32 - c).powi(2) + (y as f32 - c).powi(2)).sqrt();
            let ring = (edge - (d - ring_r).abs()).clamp(0.0, 1.0);
            let dot = (edge - (d - dot_r)).clamp(0.0, 1.0);
            out.extend_from_slice(&[0, 0, 0, (ring.max(dot) * 255.0) as u8]);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn alpha(img: &[u8], size: u32, x: u32, y: u32) -> u8 {
        img[((y * size + x) * 4 + 3) as usize]
    }

    #[test]
    fn is_a_black_rgba_image_of_the_requested_size() {
        let img = template_rgba(SIZE);
        assert_eq!(img.len(), (SIZE * SIZE * 4) as usize);
        assert!(img.chunks(4).all(|px| px[..3] == [0, 0, 0]));
    }

    #[test]
    fn draws_a_dot_and_a_ring_with_a_gap_and_clear_corners() {
        let img = template_rgba(SIZE);
        let mid = SIZE / 2;
        assert_eq!(alpha(&img, SIZE, mid, mid), 255, "centre dot");
        assert!(
            alpha(&img, SIZE, mid + 17, mid) > 240,
            "ring (anti-aliased)"
        );
        assert_eq!(alpha(&img, SIZE, mid + 11, mid), 0, "gap between them");
        assert_eq!(alpha(&img, SIZE, 0, 0), 0, "corner");
    }

    #[test]
    fn scales_to_other_sizes() {
        let img = template_rgba(22);
        assert_eq!(img.len(), 22 * 22 * 4);
        assert!(img.chunks(4).any(|px| px[3] > 0));
    }
}
