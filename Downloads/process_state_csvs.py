import csv
import os
import re

# Directory containing the CSV files (current directory)
DATA_DIR = os.path.dirname(os.path.abspath(__file__))

# Output subdirectory name
OUTPUT_SUBDIR = "Processed"

# Regex for state abbreviation CSV files (e.g., TN.csv, tn.csv, Tx.csv)
STATE_FILE_PATTERN = re.compile(r"^[A-Za-z]{2}\.csv$")

def clean_field(value: str) -> str:
    """Remove double quotes and trim leading/trailing whitespace."""
    if value is None:
        return ""
    return value.replace('"', "").strip()

def clean_csv_file(input_path: str, output_path: str) -> None:
    """Read input CSV, clean fields, and write to output CSV."""
    with open(input_path, "r", newline="", encoding="utf-8") as infile,          open(output_path, "w", newline="", encoding="utf-8") as outfile:

        reader = csv.reader(infile)
        writer = csv.writer(outfile, quoting=csv.QUOTE_MINIMAL)

        for row in reader:
            writer.writerow([clean_field(field) for field in row])

def process_directory(directory: str) -> None:
    output_dir = os.path.join(directory, OUTPUT_SUBDIR)
    os.makedirs(output_dir, exist_ok=True)

    for filename in os.listdir(directory):
        if not STATE_FILE_PATTERN.match(filename):
            continue

        input_path = os.path.join(directory, filename)
        if not os.path.isfile(input_path):
            continue

        output_path = os.path.join(output_dir, filename)
        print(f"Processing: {filename} -> {OUTPUT_SUBDIR}/{filename}")
        clean_csv_file(input_path, output_path)

if __name__ == "__main__":
    process_directory(DATA_DIR)
