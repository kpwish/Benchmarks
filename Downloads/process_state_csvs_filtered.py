import csv
import os
import re

# Directory containing the CSV files (current directory)
DATA_DIR = os.path.dirname(os.path.abspath(__file__))

# Output subdirectory name
OUTPUT_SUBDIR = "Processed"

# Regex for state abbreviation CSV files (e.g., TN.csv, tn.csv, Tx.csv)
STATE_FILE_PATTERN = re.compile(r"^[A-Za-z]{2}\.csv$")

# Fields to keep (order will be preserved as listed here)
RELEVANT_FIELDS = [
    "data_date",
    "data_srce",
    "pid",
    "name",
    "dec_lat",
    "dec_lon",
    "state",
    "county",
    "marker",
    "setting",
    "last_recv",
    "last_cond",
    "last_recby",
    "ortho_ht",
]

def clean_field(value: str) -> str:
    """Remove double quotes and trim leading/trailing whitespace."""
    if value is None:
        return ""
    return value.replace('"', "").strip()

def clean_and_filter_csv(input_path: str, output_path: str) -> None:
    """Read input CSV, clean fields, keep only relevant columns, and write output CSV."""
    with open(input_path, "r", newline="", encoding="utf-8") as infile,          open(output_path, "w", newline="", encoding="utf-8") as outfile:

        reader = csv.DictReader(infile)
        writer = csv.DictWriter(
            outfile,
            fieldnames=RELEVANT_FIELDS,
            extrasaction="ignore",
            quoting=csv.QUOTE_MINIMAL
        )

        writer.writeheader()

        for row in reader:
            cleaned_row = {
                field: clean_field(row.get(field, ""))
                for field in RELEVANT_FIELDS
            }
            writer.writerow(cleaned_row)

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
        clean_and_filter_csv(input_path, output_path)

if __name__ == "__main__":
    process_directory(DATA_DIR)
