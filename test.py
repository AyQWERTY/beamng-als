import os

def rename_files(directory):
    for root, dirs, files in os.walk(directory):
        for file in files:
            if file == "keyboard.json":
                old_path = os.path.join(root, file)
                new_path = os.path.join(root, "keyboardALS.json")
                os.rename(old_path, new_path)
                print(f"Renamed file: {old_path} -> {new_path}")

# Replace "/d:/BeamNgUser/BeamNG.drive/0.31/mods/unpacked/tunableEnginesALS_0.31" with your desired directory path
directory_path = "d:/BeamNgUser/BeamNG.drive/0.31/mods/unpacked/tunableEnginesALS_0.31"
rename_files(directory_path)