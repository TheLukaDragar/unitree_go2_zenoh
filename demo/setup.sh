#!/bin/bash
set -e

echo "Setting up Luka's Robot Code Environment"
echo "========================================"

# Store the original directory
ORIGINAL_DIR="$(pwd)"

# Check if uv is installed
if ! command -v uv &> /dev/null; then
    echo "uv is not installed. Please install it first:"
    echo "curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

echo "Found uv"

# Check if cmake is available
if ! command -v cmake &> /dev/null; then
    echo "cmake is not installed. Installing via brew..."
    if command -v brew &> /dev/null; then
        brew install cmake
    else
        echo "Please install cmake manually"
        exit 1
    fi
fi

echo "Found cmake"

# Check if Python 3.12 is available
if ! command -v python3.12 &> /dev/null; then
    echo "Python 3.12 is not installed. Installing via brew..."
    if command -v brew &> /dev/null; then
        brew install python@3.12
    else
        echo "Please install Python 3.12 manually"
        exit 1
    fi
fi

echo "Found Python 3.12"

# Create cyclonedds directory if it doesn't exist
CYCLONEDDS_DIR="$HOME/cyclonedds"
if [ ! -d "$CYCLONEDDS_DIR" ]; then
    echo "Cloning CyclonDDS..."
    cd "$HOME"
    git clone https://github.com/eclipse-cyclonedds/cyclonedds -b releases/0.10.x cyclonedds
    echo "CyclonDDS cloned"
else
    echo "CyclonDDS already exists"
fi

# Build CyclonDDS if not already built
if [ ! -d "$CYCLONEDDS_DIR/install" ]; then
    echo "Building CyclonDDS..."
    cd "$CYCLONEDDS_DIR"
    mkdir -p build install
    cd build
    cmake .. -DCMAKE_INSTALL_PREFIX=../install
    cmake --build . --target install
    echo "CyclonDDS built and installed"
else
    echo "CyclonDDS already built"
fi

# Go back to original project directory
cd "$ORIGINAL_DIR"

# Set environment variables
echo "Setting environment variables..."
export CYCLONEDDS_HOME="$HOME/cyclonedds/install"
export CMAKE_PREFIX_PATH="$CYCLONEDDS_HOME:$CMAKE_PREFIX_PATH"

echo "Installing project dependencies with uv (using Python 3.12)..."
CYCLONEDDS_HOME="$HOME/cyclonedds/install" CMAKE_PREFIX_PATH="$HOME/cyclonedds/install:$CMAKE_PREFIX_PATH" uv sync --python 3.12

# Install unitree_sdk2py using the official method
echo "Installing unitree_sdk2py..."
UNITREE_SDK_DIR="$ORIGINAL_DIR/unitree_sdk2_python"
if [ ! -d "$UNITREE_SDK_DIR" ]; then
    echo "Cloning unitree_sdk2_python..."
    cd "$ORIGINAL_DIR"
    git clone https://github.com/unitreerobotics/unitree_sdk2_python.git
    echo "unitree_sdk2_python cloned"
else
    echo "unitree_sdk2_python already exists"
fi

echo "Installing unitree_sdk2py in editable mode..."
cd "$ORIGINAL_DIR"
CYCLONEDDS_HOME="$HOME/cyclonedds/install" CMAKE_PREFIX_PATH="$HOME/cyclonedds/install:$CMAKE_PREFIX_PATH" uv pip install -e "$UNITREE_SDK_DIR"
echo "unitree_sdk2py installed"

# Go back to project directory
cd "$ORIGINAL_DIR"

echo ""
echo "Setup complete!"
echo ""
echo "To run the DDS test:"
echo "  uv run test_dds.py"
echo ""
echo "Don't forget to set these environment variables in your shell:"
echo "  export CYCLONEDDS_HOME=\"$HOME/cyclonedds/install\""
echo "  export CMAKE_PREFIX_PATH=\"$HOME/cyclonedds/install:\$CMAKE_PREFIX_PATH\"" 