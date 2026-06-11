use crate::types::Color;

pub const TILE_SIZE: usize = 8;
pub type StyleTiles = [[u8; TILE_SIZE]; TILE_SIZE];

#[derive(Debug, Clone, Copy)]
pub struct BuildingStyle {
    pub tiles: StyleTiles,
}

pub const BUILDING_STYLES: [BuildingStyle; 6] = [
    BuildingStyle {
        tiles: [
            [0, 0, 0, 0, 1, 0, 0, 1],
            [0, 0, 0, 0, 1, 0, 0, 1],
            [0, 0, 0, 0, 1, 0, 0, 1],
            [0, 0, 0, 0, 1, 0, 0, 1],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ],
    },
    BuildingStyle {
        tiles: [
            [1, 1, 0, 0, 1, 1, 0, 0],
            [1, 1, 0, 0, 1, 1, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ],
    },
    BuildingStyle {
        tiles: [
            [1, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ],
    },
    BuildingStyle {
        tiles: [
            [0, 1, 0, 1, 0, 1, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ],
    },
    BuildingStyle {
        tiles: [
            [1, 0, 0, 0, 1, 0, 0, 0],
            [1, 0, 0, 0, 1, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 1, 0, 0, 0],
            [1, 0, 0, 0, 1, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ],
    },
    BuildingStyle {
        tiles: [
            [0, 1, 1, 0, 1, 1, 0, 0],
            [0, 1, 1, 0, 1, 1, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ],
    },
];

#[derive(Debug, Clone, Copy)]
pub struct Building {
    pub start_x: i32,
    pub start_y: i32,
    pub width: i32,
    pub height: i32,
    pub z: i32,
    pub style_idx: usize,
}

impl Building {
    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.start_x
            && x < self.start_x + self.width
            && y >= self.start_y
            && y < self.start_y + self.height
    }

    pub fn is_light_on(&self, x: i32, y: i32) -> bool {
        if !self.contains(x, y) {
            return false;
        }
        let style = &BUILDING_STYLES[self.style_idx];
        let tx = ((x - self.start_x).rem_euclid(TILE_SIZE as i32)) as usize;
        let ty = ((y - self.start_y).rem_euclid(TILE_SIZE as i32)) as usize;
        style.tiles[ty][tx] == 1
    }
}

pub const BUILDING_COLOR: Color = Color::new(0.972, 0.945, 0.012);
pub const FLASHER_COLOR: Color = Color::new(1.0, 0.0, 0.0);
