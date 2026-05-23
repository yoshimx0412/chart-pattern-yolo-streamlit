import io
import time
from datetime import datetime, timedelta
from pathlib import Path

import cv2
import streamlit as st
import torch
from ultralytics import YOLO
from ultralytics.utils.checks import check_requirements
from ultralytics.utils.downloads import GITHUB_ASSETS_STEMS


BASE_DIR = Path(__file__).resolve().parent
LOGO_PATH = BASE_DIR / "images" / "DTDB1.png"
LOCAL_MODEL_PATH = BASE_DIR / "weights" / "best.pt"
UPLOAD_PATH = BASE_DIR / "uploaded_video.mp4"
DISPLAY_IMAGE_WIDTH = 640
DETECTION_RESET_SECONDS = 60


def list_camera_devices(max_devices: int = 10) -> list[str]:
    """Return available local camera devices as Streamlit option labels."""
    devices = []
    for index in range(max_devices):
        cap = cv2.VideoCapture(index)
        success, _ = cap.read()
        cap.release()
        if success:
            devices.append(f"Camera {index}")
    return devices


def save_uploaded_video(uploaded_file) -> str | None:
    if uploaded_file is None:
        return None

    video_bytes = io.BytesIO(uploaded_file.read())
    with UPLOAD_PATH.open("wb") as out:
        out.write(video_bytes.read())
    return str(UPLOAD_PATH)


@st.cache_resource
def load_yolo_model(model_ref: str) -> YOLO:
    return YOLO(model_ref)


def build_model_options() -> list[str]:
    options = []
    if LOCAL_MODEL_PATH.exists():
        options.append("best.pt (custom chart pattern model)")

    options.extend(
        x.replace("yolo", "YOLO")
        for x in GITHUB_ASSETS_STEMS
        if x.startswith("yolov8")
    )
    return options


def resolve_model_ref(selected_model: str) -> str:
    if selected_model.startswith("best.pt"):
        return str(LOCAL_MODEL_PATH)
    return f"{selected_model.lower()}.pt"


def draw_boundary(frame, boundary_x: int, boundary_percentage: float, height: int):
    cv2.line(frame, (boundary_x, 0), (boundary_x, height), (255, 255, 0), 2)
    cv2.putText(
        frame,
        f"Boundary: {boundary_percentage:.0f}%",
        (min(boundary_x + 10, frame.shape[1] - 260), 30),
        cv2.FONT_HERSHEY_SIMPLEX,
        1,
        (255, 255, 0),
        2,
        cv2.LINE_AA,
    )


def main():
    check_requirements("streamlit>=1.29.0")

    st.set_page_config(
        page_title="Chart Pattern Detection",
        layout="wide",
        initial_sidebar_state="auto",
    )

    st.markdown("<style>MainMenu {visibility: hidden;}</style>", unsafe_allow_html=True)
    st.markdown(
        """
        <div>
            <h1 style="color:#FF64DA; text-align:center; font-size:40px;
                       font-family: Arial, sans-serif; margin-top:-50px; margin-bottom:20px;">
                Double Top / Bottom Scanner
            </h1>
            <h4 style="color:#042AFF; text-align:center;
                       font-family: Arial, sans-serif; margin-top:-15px; margin-bottom:50px;">
                Chart pattern detection with YOLOv8
            </h4>
        </div>
        """,
        unsafe_allow_html=True,
    )

    with st.sidebar:
        if LOGO_PATH.exists():
            st.image(str(LOGO_PATH), width=250)
        st.title("User Configuration")

    frame_rate = st.sidebar.slider(
        "Frame Rate (FPS)",
        min_value=1,
        max_value=30,
        value=10,
        step=1,
        help="Sets the target frame rate for processing.",
    )
    frame_interval = 1.0 / frame_rate

    camera_devices = list_camera_devices()
    source_options = camera_devices + ["Video File"]
    source = st.sidebar.selectbox("Video Source", source_options)
    manual_camera_index = st.sidebar.text_input("Manual Camera Index", value="0")

    resolutions = ["1920x1080", "1280x720", "640x480", "320x240"]
    selected_resolution = st.sidebar.selectbox("Resolution", resolutions, index=1)
    width, height = map(int, selected_resolution.split("x"))

    boundary_percentage = st.sidebar.slider(
        "Boundary Line Position (%)",
        min_value=0.0,
        max_value=100.0,
        value=75.0,
        step=1.0,
        help="Places the alert boundary as a percentage of frame width.",
    )
    boundary_x = int((boundary_percentage / 100.0) * width)

    vid_file_name = None
    if source == "Video File":
        uploaded_video = st.sidebar.file_uploader(
            "Upload Video File",
            type=["mp4", "mov", "avi", "mkv"],
        )
        vid_file_name = save_uploaded_video(uploaded_video)
    else:
        try:
            vid_file_name = int(manual_camera_index)
        except ValueError:
            vid_file_name = int(source.split()[1])

    model_options = build_model_options()
    selected_model = st.sidebar.selectbox("Model", model_options)
    model_ref = resolve_model_ref(selected_model)

    with st.spinner("Loading model..."):
        model_instance = load_yolo_model(model_ref)
        class_names = list(model_instance.names.values())
    st.success("Model loaded successfully.")

    selected_classes = st.sidebar.multiselect(
        "Classes",
        class_names,
        default=class_names,
    )
    selected_indices = [class_names.index(option) for option in selected_classes]

    enable_tracking = st.sidebar.radio("Enable Tracking", ("Yes", "No"))
    confidence = float(st.sidebar.slider("Confidence Threshold", 0.0, 1.0, 0.25, 0.01))
    iou = float(st.sidebar.slider("IoU Threshold", 0.0, 1.0, 0.45, 0.01))

    col1, col2 = st.columns(2)
    org_frame = col1.empty()
    ann_frame = col2.empty()
    fps_display = st.sidebar.empty()
    event_display = st.sidebar.empty()

    if source == "Video File" and vid_file_name is None:
        st.info("Upload a video file, then press Start.")
        return

    if st.sidebar.button("Start"):
        videocapture = cv2.VideoCapture(vid_file_name)

        if not videocapture.isOpened():
            st.error(f"Could not open video source: {vid_file_name}")
            st.stop()

        videocapture.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        videocapture.set(cv2.CAP_PROP_FRAME_HEIGHT, height)

        stop_button = st.button("Stop")
        last_detection_time = datetime.min

        while videocapture.isOpened():
            start_time = time.time()
            success, frame = videocapture.read()
            if not success:
                st.warning("Failed to read frame from video source.")
                break

            frame = cv2.resize(frame, (width, height))
            inference_started_at = time.time()

            if enable_tracking == "Yes":
                results = model_instance.track(
                    frame,
                    conf=confidence,
                    iou=iou,
                    classes=selected_indices,
                    persist=True,
                )
            else:
                results = model_instance(
                    frame,
                    conf=confidence,
                    iou=iou,
                    classes=selected_indices,
                )

            annotated_frame = results[0].plot()
            draw_boundary(annotated_frame, boundary_x, boundary_percentage, height)

            right_side_detections = []
            for det in results[0].boxes:
                x1, _, x2, _ = det.xyxy[0].cpu().numpy()
                center_x = (x1 + x2) / 2
                if center_x > boundary_x:
                    right_side_detections.append(det)

            current_time = datetime.now()
            if (
                right_side_detections
                and current_time - last_detection_time
                > timedelta(seconds=DETECTION_RESET_SECONDS)
            ):
                detected_classes = [
                    class_names[int(det.cls)] for det in right_side_detections
                ]
                unique_classes = ", ".join(sorted(set(detected_classes)))
                event_display.warning(
                    f"Detected on right side: {unique_classes} "
                    f"({current_time:%H:%M:%S})"
                )
                last_detection_time = current_time

            fps = 1 / max(time.time() - inference_started_at, 1e-9)
            org_frame.image(frame, channels="BGR", width=DISPLAY_IMAGE_WIDTH)
            ann_frame.image(annotated_frame, channels="BGR", width=DISPLAY_IMAGE_WIDTH)
            fps_display.metric("FPS", f"{fps:.2f}")

            if stop_button:
                break

            elapsed_time = time.time() - start_time
            sleep_time = frame_interval - elapsed_time
            if sleep_time > 0:
                time.sleep(sleep_time)

        videocapture.release()

    torch.cuda.empty_cache()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
