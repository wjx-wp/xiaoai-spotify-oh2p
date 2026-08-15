use std::ffi::{c_char, c_int, c_void};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::mem;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const ENGINE_VTABLE_ENTRIES: usize = 64;
const CAPABILITY_VTABLE_ENTRIES: usize = 16;
const ENGINE_REGISTER_SLOT: usize = 0;
const CAPABILITY_PROCESS_SLOT: usize = 3;
const MAX_STRING: usize = 4096;
const MAX_DIALOG: usize = 127;
const ACTIVE_TTL: Duration = Duration::from_secs(30);
// Verified against OH2P firmware 1.56.20's libaivs_sdk.so:
// AudioPlayer::Play stores optional Common::AudioType at payload + 0x1c,
// and Common::StringToAudioType("MUSIC") returns enum value 1.
const AUDIO_PLAYER_TYPE_OFFSET: usize = 0x1c;
const AUDIO_TYPE_MUSIC: u32 = 1;

static ORIGINAL_REGISTER: AtomicUsize = AtomicUsize::new(0);
static ORIGINAL_PROCESS: AtomicUsize = AtomicUsize::new(0);
static ORIGINAL_CREATE: OnceLock<usize> = OnceLock::new();
static FILTER_MODE: OnceLock<FilterMode> = OnceLock::new();
static FILTER_STATE: OnceLock<Mutex<FilterState>> = OnceLock::new();
static LOG_FILE: OnceLock<Mutex<File>> = OnceLock::new();

#[repr(C)]
pub struct SharedPtr {
    ptr: *mut (),
    ctrl: *mut (),
}

#[repr(C)]
struct GnuString32 {
    ptr: *const c_char,
    len: u32,
    storage: [u8; 16],
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum FilterMode {
    Observe,
    Active,
}

struct FilterState {
    dialog: [u8; MAX_DIALOG + 1],
    dialog_len: usize,
    expires_at: Instant,
}

impl FilterState {
    fn new() -> Self {
        Self {
            dialog: [0; MAX_DIALOG + 1],
            dialog_len: 0,
            expires_at: Instant::now(),
        }
    }

    fn set_dialog(&mut self, dialog: &str) {
        let bytes = dialog.as_bytes();
        let len = bytes.len().min(MAX_DIALOG);
        self.dialog[..len].copy_from_slice(&bytes[..len]);
        self.dialog_len = len;
        self.expires_at = Instant::now() + ACTIVE_TTL;
    }

    fn clear(&mut self) {
        self.dialog_len = 0;
    }

    fn matches(&mut self, dialog: &str) -> bool {
        if Instant::now() > self.expires_at {
            self.clear();
            return false;
        }
        self.dialog_len != 0 && self.dialog[..self.dialog_len] == *dialog.as_bytes()
    }
}

type EngineCreate = unsafe extern "C" fn(
    output: *mut SharedPtr,
    config: *mut SharedPtr,
    client_info: *mut SharedPtr,
    mode: c_int,
);
type RegisterCapability = unsafe extern "C" fn(*mut (), *mut SharedPtr) -> c_int;
type CapabilityGetName = unsafe extern "C" fn(*mut ()) -> *const GnuString32;
type InstructionProcess = unsafe extern "C" fn(*mut (), *mut SharedPtr) -> c_int;

#[link(name = "dl")]
extern "C" {
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlopen(filename: *const c_char, flags: c_int) -> *mut c_void;
}

fn mode() -> FilterMode {
    *FILTER_MODE.get_or_init(|| match std::env::var("XIAOAI_FILTER_MODE") {
        Ok(value) if value.eq_ignore_ascii_case("active") => FilterMode::Active,
        _ => FilterMode::Observe,
    })
}

fn filter_state() -> &'static Mutex<FilterState> {
    FILTER_STATE.get_or_init(|| Mutex::new(FilterState::new()))
}

fn log_line(message: &str) {
    let file = LOG_FILE.get_or_init(|| {
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open("/tmp/xiaoaimusic-aivs-filter.log")
            .unwrap_or_else(|_| File::open("/dev/null").expect("open /dev/null"));
        Mutex::new(file)
    });
    if let Ok(mut file) = file.try_lock() {
        let _ = writeln!(file, "{message}");
    }
}

unsafe fn real_create() -> Option<EngineCreate> {
    let address = *ORIGINAL_CREATE.get_or_init(|| {
        let symbol = b"_ZN4aivs6Engine6createERSt10shared_ptrINS_10AivsConfigEERS1_INS_8Settings10ClientInfoEEi\0";
        let mut address = dlsym((-1isize) as *mut c_void, symbol.as_ptr().cast());
        if address.is_null() {
            let library = dlopen(b"libaivs_sdk.so\0".as_ptr().cast(), 2);
            if !library.is_null() {
                address = dlsym(library, symbol.as_ptr().cast());
            }
        }
        address as usize
    });
    if address == 0 {
        None
    } else {
        Some(mem::transmute::<usize, EngineCreate>(address))
    }
}

unsafe fn replace_vtable_slot(
    object: *mut (),
    entry_count: usize,
    slot: usize,
    replacement: usize,
) -> Option<usize> {
    if object.is_null() || slot >= entry_count {
        return None;
    }
    let object_vptr = object.cast::<*const usize>();
    let original_vtable = ptr::read_unaligned(object_vptr);
    if original_vtable.is_null() {
        return None;
    }
    let mut copied = slice::from_raw_parts(original_vtable, entry_count).to_vec();
    let original = copied[slot];
    copied[slot] = replacement;
    let copied = Box::leak(copied.into_boxed_slice());
    ptr::write_unaligned(object_vptr, copied.as_ptr());
    Some(original)
}

unsafe fn vtable_slot(object: *mut (), entry_count: usize, slot: usize) -> Option<usize> {
    if object.is_null() || slot >= entry_count {
        return None;
    }
    let vtable = ptr::read_unaligned(object.cast::<*const usize>());
    if vtable.is_null() {
        return None;
    }
    Some(ptr::read_unaligned(vtable.add(slot)))
}

unsafe fn read_gnu_string<'a>(string: *const GnuString32) -> Option<&'a str> {
    if string.is_null() {
        return None;
    }
    let len = ptr::read_unaligned(ptr::addr_of!((*string).len)) as usize;
    let data = ptr::read_unaligned(ptr::addr_of!((*string).ptr)).cast::<u8>();
    if data.is_null() || len > MAX_STRING {
        return None;
    }
    std::str::from_utf8(slice::from_raw_parts(data, len)).ok()
}

unsafe fn embedded_string<'a>(base: *const u8, offset: usize) -> Option<&'a str> {
    if base.is_null() {
        return None;
    }
    read_gnu_string(base.add(offset).cast::<GnuString32>())
}

unsafe fn pointed_string<'a>(base: *const u8, offset: usize) -> Option<&'a str> {
    read_gnu_string(pointer_at(base, offset).cast::<GnuString32>())
}

unsafe fn pointer_at(base: *const u8, offset: usize) -> *const u8 {
    if base.is_null() {
        ptr::null()
    } else {
        ptr::read_unaligned(base.add(offset).cast::<u32>()) as usize as *const u8
    }
}

unsafe fn recognize_text<'a>(payload: *const u8) -> Option<(bool, &'a str)> {
    if payload.is_null() {
        return None;
    }
    let final_flag = ptr::read_unaligned(payload.add(4)) != 0;
    let begin = pointer_at(payload, 8);
    let end = pointer_at(payload, 12);
    if begin.is_null() || end.is_null() || begin >= end {
        return None;
    }
    let result = ptr::read_unaligned(begin.cast::<u32>()) as usize as *const u8;
    if result.is_null() {
        return None;
    }
    let text_ptr = ptr::read_unaligned(result.add(4).cast::<u32>()) as usize as *const u8;
    let text_len = ptr::read_unaligned(result.add(8).cast::<u32>()) as usize;
    if text_ptr.is_null() || text_len > MAX_STRING {
        return None;
    }
    std::str::from_utf8(slice::from_raw_parts(text_ptr, text_len))
        .ok()
        .map(|text| (final_flag, text))
}

unsafe fn audio_player_type(payload: *const u8) -> Option<u32> {
    let value = pointer_at(payload, AUDIO_PLAYER_TYPE_OFFSET);
    if value.is_null() {
        None
    } else {
        Some(ptr::read_unaligned(value.cast::<u32>()))
    }
}

fn is_music_intent(text: &str) -> bool {
    let text = text.trim();
    const EXACT: &[&str] = &[
        "暂停", "暂停播放", "暂停音乐", "停止", "停止播放", "停止音乐", "关闭音乐",
        "关掉音乐", "音乐关掉", "闭嘴", "别放了", "不要播放了", "继续", "继续播放",
        "继续音乐", "恢复播放", "下一首", "下一曲", "切歌", "上一首", "上一曲",
        "随机播放", "打开随机播放", "开启随机播放", "关闭随机播放", "不要随机播放",
        "单曲循环", "列表循环", "歌单循环", "关闭循环", "不要循环",
        "同步点赞音乐", "同步点赞歌曲", "同步收藏音乐", "同步收藏歌曲", "刷新点赞音乐", "刷新收藏音乐",
    ];
    if EXACT.contains(&text) {
        return true;
    }
    const PREFIXES: &[&str] = &[
        "播放", "帮我播放", "请播放", "给我播放", "放一首", "放一个", "放点音乐",
        "放点歌", "放音乐", "随便播放", "随便放", "来一首", "来点歌", "来点音乐",
        "听点歌", "听点音乐", "推荐点歌", "推荐一些歌",
    ];
    PREFIXES.iter().any(|prefix| text.starts_with(prefix))
}

unsafe fn inspect_instruction(instruction: *mut SharedPtr) -> bool {
    if instruction.is_null() || (*instruction).ptr.is_null() {
        return false;
    }
    let object = (*instruction).ptr.cast::<u8>();
    let header = pointer_at(object, 28);
    let payload = pointer_at(object, 36);
    let namespace = match embedded_string(header, 4) {
        Some(value) => value,
        None => return false,
    };
    let name = embedded_string(header, 28).unwrap_or("");
    // InstructionHeader stores dialog_id as an optional GNU string pointer at
    // +76. InstructionHeader::toJson checks the pointer, dereferences it, then
    // serializes the returned std::__cxx11::string.
    let dialog = pointed_string(header, 76).unwrap_or("");
    let filter_mode = mode();
    log_line(&format!(
        "INSTRUCTION mode={} namespace={namespace} name={name} dialog={dialog}",
        if filter_mode == FilterMode::Active {
            "active"
        } else {
            "observe"
        }
    ));

    // A verified MUSIC payload is the authoritative cloud decision.  Handle
    // it before taking the classifier state lock so concurrent callbacks can
    // never make native music fail open merely because the lock is busy.
    let play_type = if namespace == "AudioPlayer" && name == "Play" {
        audio_player_type(payload)
    } else {
        None
    };
    if filter_mode == FilterMode::Active {
        match play_type {
            Some(AUDIO_TYPE_MUSIC) => {
                log_line(&format!(
                    "DROP namespace=AudioPlayer name=Play audio_type=MUSIC dialog={dialog} source=payload"
                ));
                return true;
            }
            Some(value) => {
                log_line(&format!(
                    "PASS namespace=AudioPlayer name=Play audio_type={value} dialog={dialog}"
                ));
                return false;
            }
            None => {}
        }
    }

    let mut state = match filter_state().try_lock() {
        Ok(state) => state,
        Err(_) => return false,
    };

    if namespace == "SpeechRecognizer" && name == "RecognizeResult" {
        if let Some((true, text)) = recognize_text(payload) {
            let music = !dialog.is_empty() && is_music_intent(text);
            log_line(&format!("ASR music={music} dialog={dialog} text={text}"));
            if music {
                state.set_dialog(dialog);
            } else if state.matches(dialog) {
                state.clear();
            }
        }
        return false;
    }

    if namespace == "Dialog" && name == "Finish" {
        if state.matches(dialog) {
            state.clear();
        }
        return false;
    }

    if filter_mode != FilterMode::Active {
        return false;
    }

    let classified_dialog = state.matches(dialog);
    if namespace == "AudioPlayer" && name == "Play" {
        match play_type {
            None if classified_dialog => {
                log_line(&format!(
                    "DROP namespace=AudioPlayer name=Play audio_type=unknown dialog={dialog} source=classified-dialog"
                ));
                return true;
            }
            None => {
                log_line(&format!(
                    "PASS namespace=AudioPlayer name=Play audio_type=unknown dialog={dialog}"
                ));
                return false;
            }
            Some(_) => return false,
        }
    }

    if classified_dialog && namespace == "SpeechSynthesizer" && name == "Speak" {
        log_line(&format!("DROP namespace={namespace} name={name} dialog={dialog}"));
        return true;
    }
    false
}

unsafe extern "C" fn instruction_process_proxy(
    this: *mut (),
    instruction: *mut SharedPtr,
) -> c_int {
    let original = ORIGINAL_PROCESS.load(Ordering::Acquire);
    if original == 0 {
        return 0;
    }
    let original: InstructionProcess = mem::transmute(original);
    let drop = catch_unwind(AssertUnwindSafe(|| inspect_instruction(instruction))).unwrap_or(false);
    if drop {
        1
    } else {
        original(this, instruction)
    }
}

unsafe fn wrap_capability(capability: *mut SharedPtr) {
    if capability.is_null() || (*capability).ptr.is_null() {
        return;
    }
    let object = (*capability).ptr;
    let vtable = ptr::read_unaligned(object.cast::<*const usize>());
    if vtable.is_null() {
        return;
    }
    let get_name: CapabilityGetName = mem::transmute(ptr::read_unaligned(vtable));
    let name = read_gnu_string(get_name(object)).unwrap_or("");
    log_line(&format!("CAPABILITY name={name}"));
    if name != "InstructionCapability" {
        return;
    }
    let replacement = instruction_process_proxy as *const () as usize;
    let Some(current) = vtable_slot(object, CAPABILITY_VTABLE_ENTRIES, CAPABILITY_PROCESS_SLOT)
    else {
        return;
    };
    if current == replacement {
        return;
    }
    let recorded = ORIGINAL_PROCESS.load(Ordering::Acquire);
    if recorded != 0 && recorded != current {
        log_line("ERROR capability=InstructionCapability reason=process-abi-mismatch");
        return;
    }
    if let Some(original) = replace_vtable_slot(
        object,
        CAPABILITY_VTABLE_ENTRIES,
        CAPABILITY_PROCESS_SLOT,
        replacement,
    ) {
        if recorded == 0 {
            ORIGINAL_PROCESS.store(original, Ordering::Release);
        }
        log_line("HOOK capability=InstructionCapability slot=3");
    }
}

unsafe extern "C" fn register_capability_proxy(
    engine: *mut (),
    capability: *mut SharedPtr,
) -> c_int {
    let original = ORIGINAL_REGISTER.load(Ordering::Acquire);
    if original == 0 {
        return 0;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| wrap_capability(capability)));
    let original: RegisterCapability = mem::transmute(original);
    original(engine, capability)
}

unsafe fn wrap_engine(output: *mut SharedPtr) {
    if output.is_null() || (*output).ptr.is_null() {
        return;
    }
    let object = (*output).ptr;
    let replacement = register_capability_proxy as *const () as usize;
    let Some(current) = vtable_slot(object, ENGINE_VTABLE_ENTRIES, ENGINE_REGISTER_SLOT) else {
        return;
    };
    if current == replacement {
        return;
    }
    let recorded = ORIGINAL_REGISTER.load(Ordering::Acquire);
    if recorded != 0 && recorded != current {
        log_line("ERROR engine=Engine reason=register-abi-mismatch");
        return;
    }
    if let Some(original) = replace_vtable_slot(
        object,
        ENGINE_VTABLE_ENTRIES,
        ENGINE_REGISTER_SLOT,
        replacement,
    ) {
        if recorded == 0 {
            ORIGINAL_REGISTER.store(original, Ordering::Release);
        }
        log_line("HOOK engine=Engine slot=0");
    }
}

#[unsafe(export_name = "_ZN4aivs6Engine6createERSt10shared_ptrINS_10AivsConfigEERS1_INS_8Settings10ClientInfoEEi")]
pub unsafe extern "C" fn aivs_engine_create_proxy(
    output: *mut SharedPtr,
    config: *mut SharedPtr,
    client_info: *mut SharedPtr,
    engine_mode: c_int,
) {
    let Some(original) = real_create() else {
        log_line("ERROR dlsym=Engine::create");
        return;
    };
    original(output, config, client_info, engine_mode);
    let _ = catch_unwind(AssertUnwindSafe(|| wrap_engine(output)));
}

#[cfg(test)]
mod tests {
    use super::is_music_intent;

    #[test]
    fn recognizes_music_and_transport_without_claiming_device_control() {
        assert!(is_music_intent("播放周杰伦"));
        assert!(is_music_intent("帮我播放我喜欢的音乐"));
        assert!(is_music_intent("暂停音乐"));
        assert!(is_music_intent("单曲循环"));
        assert!(is_music_intent("同步点赞音乐"));
        assert!(is_music_intent("随便播放一首歌曲"));
        assert!(is_music_intent("来一首歌"));
        assert!(is_music_intent("听点音乐"));
        assert!(is_music_intent("推荐点歌"));
        assert!(!is_music_intent("打开客厅的灯"));
        assert!(!is_music_intent("关闭空调"));
        assert!(!is_music_intent("今天天气怎么样"));
    }
}
