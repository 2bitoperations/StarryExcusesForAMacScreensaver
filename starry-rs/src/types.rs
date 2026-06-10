use rand::Rng;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Color {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

impl Color {
    pub const fn new(r: f32, g: f32, b: f32) -> Self {
        Self { r, g, b }
    }

    pub fn premul_rgba(&self, alpha: f32) -> [f32; 4] {
        [self.r * alpha, self.g * alpha, self.b * alpha, alpha]
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point {
    pub x: i32,
    pub y: i32,
    pub color: Color,
}

impl Point {
    pub const fn new(x: i32, y: i32, color: Color) -> Self {
        Self { x, y, color }
    }
}

pub fn random_star_color<R: Rng + ?Sized>(rng: &mut R) -> Color {
    Color::new(
        rng.gen_range(0.0_f32..=0.5),
        rng.gen_range(0.0_f32..=0.5),
        rng.gen_range(0.0_f32..=1.0),
    )
}
