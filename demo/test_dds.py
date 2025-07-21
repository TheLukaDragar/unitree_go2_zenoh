from unitree_sdk2py.core.channel import ChannelFactoryInitialize
from unitree_sdk2py.go2.video.video_client import VideoClient
import cv2
import numpy as np
import sys


def main():
    if len(sys.argv) > 1:
        ChannelFactoryInitialize(0, sys.argv[1])
    else:
        ChannelFactoryInitialize(0)

    client = VideoClient()  # Create a video client
    client.SetTimeout(3.0)
    client.Init()

    code, data = client.GetImageSample()

    # Check if we got valid data
    if code != 0:
        print(f"Failed to get initial image sample. Error code: {code}")
        print("Make sure the robot is connected and the video service is running.")
        return

    # Request normal when code==0
    while code == 0:
        # Get Image data from Go2 robot
        code, data = client.GetImageSample()

        if code != 0:
            break

        # Convert to numpy image
        image_data = np.frombuffer(bytes(data), dtype=np.uint8)
        image = cv2.imdecode(image_data, cv2.IMREAD_COLOR)

        # Check if image was decoded successfully
        if image is None or image.size == 0:
            print("Warning: Received empty or invalid image data")
            continue

        # Display image
        cv2.imshow("front_camera", image)
        # Press ESC to stop
        if cv2.waitKey(20) == 27:
            break

    if code != 0:
        print("Get image sample error. code:", code)
    else:
        # Capture an image
        if 'image' in locals() and image is not None:
            cv2.imwrite("front_image.jpg", image)
            print("Saved image as front_image.jpg")

    cv2.destroyWindow("front_camera")


if __name__ == "__main__":
    main()
