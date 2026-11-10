//! Shapes.

/// A square.
pub const Square = struct {
    side: u32,
};

/// The area of a square.
pub fn area(s: Square) u32 {
    return s.side * s.side;
}
