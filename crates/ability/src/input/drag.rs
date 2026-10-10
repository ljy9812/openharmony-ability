//! Native drag/drop policy built on owned, typed platform bindings.
use crate::OpenHarmonyWaker;
use napi_ohos::{Error, Result};
use ohos_arkui_binding::{
    api::drag::{DragAction, DragEvent},
    component::attribute::ArkUIAttributeBasic,
    image_native_binding::{
        PixelFormat, PixelMap, PixelMapAlphaType, PixelMapInitializationOptions,
    },
    types::advanced::DragStatus,
    XComponent,
};
use ohos_udmf_binding::{UdmfData, UdmfRecord, UdsFileUri};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DragPhase {
    Enter,
    Move,
    Leave,
    Drop,
}

#[derive(Clone, Debug, Default)]
pub struct DragResponse(Arc<AtomicBool>);
impl DragResponse {
    pub fn accept(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub fn accepted(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}
impl PartialEq for DragResponse {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DragInputData {
    pub phase: DragPhase,
    /// Physical pixels relative to the window, including native content offsets.
    pub window_x: f32,
    pub window_y: f32,
    pub file_uris: Vec<String>,
    pub response: DragResponse,
}

impl DragInputData {
    /// Copies callback-scoped data. No native event or record escapes delivery.
    pub(crate) fn from_event(event: &DragEvent<'_>, phase: DragPhase) -> Self {
        let mut file_uris = Vec::new();
        if matches!(phase, DragPhase::Enter | DragPhase::Drop) {
            if let Ok(mut data) = UdmfData::try_new() {
                if event.get_udmf_data(&mut data).is_ok() && (0..=512).contains(&data.count()) {
                    if let Ok(records) = data.records() {
                        for record in records {
                            let Ok(uri) = record.file_uri().and_then(|uri| uri.file_uri()) else {
                                continue;
                            };
                            if uri.starts_with("file://") && !file_uris.contains(&uri) {
                                file_uris.push(uri);
                            }
                        }
                    }
                }
            }
        }
        Self {
            phase,
            window_x: event.touch_point_x_to_window(),
            window_y: event.touch_point_y_to_window(),
            file_uris,
            response: DragResponse::default(),
        }
    }
}

/// UI-thread owner of an outbound native file drag.
/// Keep the source surface alive until completion, and drop this before releasing that surface.
pub struct NativeFileDrag {
    // Native action disposal unregisters callbacks before releasing its data and preview.
    _action: DragAction,
    ended: Arc<AtomicBool>,
    _source: XComponent,
    _pixels: Vec<u8>,
    _records: Vec<UdmfRecord>,
    _uris: Vec<UdsFileUri>,
}

impl NativeFileDrag {
    /// Capture a typed source view, then release the surface lock before `start`
    /// because ArkUI can synchronously reenter input dispatch.
    pub fn node_handle(component: &XComponent) -> XComponent {
        component.clone()
    }

    pub fn start(
        source: XComponent,
        pointer_id: i32,
        files: &[(String, bool)],
        waker: OpenHarmonyWaker,
    ) -> Result<Self> {
        if files.is_empty() || files.len() > 512 {
            return Err(Error::from_reason("Native drag requires 1..512 files"));
        }
        let mut data = UdmfData::try_new().map_err(|e| Error::from_reason(e.to_string()))?;
        let mut records = Vec::with_capacity(files.len());
        let mut uris = Vec::with_capacity(files.len());
        for (value, directory) in files {
            if !value.starts_with("file://") {
                return Err(Error::from_reason("Native drag requires file:// URIs"));
            }
            let uri = UdsFileUri::new().map_err(|e| Error::from_reason(e.to_string()))?;
            uri.set_file_uri(value)
                .map_err(|e| Error::from_reason(e.to_string()))?;
            uri.set_file_type(if *directory {
                "general.folder"
            } else {
                "general.file"
            })
            .map_err(|e| Error::from_reason(e.to_string()))?;
            let record = UdmfRecord::try_new().map_err(|e| Error::from_reason(e.to_string()))?;
            record
                .add_file_uri(&uri)
                .map_err(|e| Error::from_reason(e.to_string()))?;
            data.add_record(&record)
                .map_err(|e| Error::from_reason(e.to_string()))?;
            records.push(record);
            uris.push(uri);
        }
        let mut options =
            PixelMapInitializationOptions::new().map_err(|e| Error::from_reason(e.to_string()))?;
        options
            .set_width(32)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        options
            .set_height(32)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        options
            .set_pixel_format(PixelFormat::Bgra8888)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        options
            .set_alpha_type(PixelMapAlphaType::Opaque)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        let mut pixels = vec![0u8; 32 * 32 * 4];
        for pixel in pixels.as_chunks_mut::<4>().0 {
            pixel.copy_from_slice(&[0x55, 0xc7, 0x3c, 0xff]);
        }
        let preview = PixelMap::create(&mut pixels, &mut options)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        let mut action = DragAction::new_with_node(source.raw())
            .map_err(|e| Error::from_reason(e.to_string()))?;
        action
            .set_pixel_maps(vec![preview])
            .map_err(|e| Error::from_reason(e.to_string()))?;
        action
            .set_pointer_id(pointer_id)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        action
            .set_data(data)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        let ended = Arc::new(AtomicBool::new(false));
        let completed = ended.clone();
        action
            .register_status_listener(move |status| {
                if status == DragStatus::Ended {
                    completed.store(true, Ordering::Release);
                    waker.wake();
                }
            })
            .map_err(|e| Error::from_reason(e.to_string()))?;
        action
            .start_drag()
            .map_err(|e| Error::from_reason(e.to_string()))?;
        Ok(Self {
            _action: action,
            ended,
            _source: source,
            _pixels: pixels,
            _records: records,
            _uris: uris,
        })
    }

    pub fn ended(&self) -> bool {
        self.ended.load(Ordering::Acquire)
    }
}
