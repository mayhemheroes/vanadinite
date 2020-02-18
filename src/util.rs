#[derive(Debug)]
pub struct CStr(*const u8);

impl CStr {
    pub unsafe fn new(base: *const u8) -> Self {
        CStr(base)
    }

    /// Length of the string not including the null terminator
    pub fn len(&self) -> usize {
        self.bytes().count()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn bytes(&self) -> impl Iterator<Item = u8> {
        let mut ptr = self.0;
        let mut done = false;

        core::iter::from_fn(move || {
            if !done {
                let b = unsafe { ptr.read() };
                ptr = unsafe { ptr.add(1) };

                if b == 0 {
                    done = true;
                    return None;
                }

                return Some(b);
            }

            None
        })
    }

    pub fn as_slice(&self) -> &[u8] {
        unsafe { core::slice::from_raw_parts(self.0, self.len()) }
    }
}

impl core::fmt::Display for CStr {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        if self.is_empty() {
            return write!(f, "<empty str>");
        }

        for byte in self.bytes() {
            write!(f, "{}", byte as char)?;
        }

        Ok(())
    }
}

pub trait PtrUtils {
    fn assert_aligned(self, align: usize);
    fn assert_aligned_to<U>(self);
    fn assert_aligned_to_self(self);
    unsafe fn align_up(self, align: usize) -> Self;
    unsafe fn align_up_to<U>(self) -> Self;
    unsafe fn align_up_to_self(self) -> Self;
}

impl<T> PtrUtils for *const T {
    fn assert_aligned(self, align: usize) {
        assert!(align.is_power_of_two());
        assert_eq!(self as usize % align, 0, "assert: unaligned ptr");
    }

    fn assert_aligned_to<U>(self) {
        self.assert_aligned(core::mem::align_of::<U>());
    }

    fn assert_aligned_to_self(self) {
        self.assert_aligned(core::mem::align_of::<T>());
    }

    unsafe fn align_up(self, align: usize) -> Self {
        let offset = self.align_offset(align);
        assert_ne!(offset, usize::max_value(), "assert: couldn't align pointer");

        self.add(offset)
    }

    unsafe fn align_up_to<U>(self) -> Self {
        self.align_up(core::mem::align_of::<U>())
    }

    unsafe fn align_up_to_self(self) -> Self {
        self.align_up(core::mem::align_of::<T>())
    }
}

impl<T> PtrUtils for *mut T {
    fn assert_aligned(self, align: usize) {
        assert!(align.is_power_of_two());
        assert_eq!(self as usize % align, 0, "assert: unaligned ptr");
    }

    fn assert_aligned_to<U>(self) {
        self.assert_aligned(core::mem::align_of::<U>());
    }

    fn assert_aligned_to_self(self) {
        self.assert_aligned(core::mem::align_of::<T>());
    }

    unsafe fn align_up(self, align: usize) -> Self {
        let offset = self.align_offset(align);
        assert_ne!(offset, usize::max_value(), "assert: couldn't align pointer");

        self.add(offset)
    }

    unsafe fn align_up_to<U>(self) -> Self {
        self.align_up(core::mem::align_of::<U>())
    }

    unsafe fn align_up_to_self(self) -> Self {
        self.align_up(core::mem::align_of::<T>())
    }
}

pub struct DebugBytesAt(*const u8);

impl DebugBytesAt {
    pub unsafe fn new(ptr: *const u8) -> Self {
        Self(ptr)
    }
}

impl core::fmt::Display for DebugBytesAt {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "{:#p}: ", self.0)?;
        let mut chars = [' '; 16];
        let as_array: &[u8; 16] = unsafe { &*(self.0.cast()) };

        for (i, byte) in as_array.iter().copied().enumerate() {
            if byte >= 32 || byte <= 127 {
                chars[i] = byte as char;
            }

            write!(f, "{:0>2x} ", byte)?;
        }

        write!(f, "  |  ")?;

        for c in chars.iter() {
            write!(f, "{}", c);
        }

        Ok(())
    }
}
