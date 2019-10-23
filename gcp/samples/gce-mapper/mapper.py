#!/usr/bin/env python3

import argparse
import requests
import json
import googleapiclient.discovery
import sqlite3
import pandas
import xlrd

name_file = "gce_machineTypes.json"

db = sqlite3.connect("machineTypes.sqlite")

def main():
    setup_db()

    parser = argparse.ArgumentParser(description = "Match compute configuration to GCE instances")
    subparser = parser.add_subparsers(dest = "action")

    parser_d = subparser.add_parser("download")
    parser_d.add_argument("-p", metavar = "project_id", help = "GCP project id for which to download available machine types", required = True)

    parser_m = subparser.add_parser("match")
    group = parser_m.add_mutually_exclusive_group(required = True)
    group.add_argument("-c", metavar = "file.csv", help = "Path to .csv file")
    group.add_argument("-x", metavar = "file.xlsx", help = "Path to .xlsx file")
    parser_m.add_argument("-z", metavar = "zone", help = "GCP zone", default = "europe-west3")

    args = parser.parse_args()

    if args.action == "download":
        download_machineTypes(args.p)
        load_machineTypes()
    elif args.action == "match":
        if args.c != None:
            match_csv(args.c, args.z)
        else:
            match_xlsx(args.x, args.z)
    else:
        parser.print_help()

def match_csv(path_csv, zone):
    columns = pandas.read_csv(path_csv).columns
    data = pandas.read_csv(path_csv, skiprows=1, names=columns)
    iterate_doc(data, zone)

def match_xlsx(path_xlsx, zone):
    x = pandas.ExcelFile(path_xlsx)
    data = x.parse(x.sheet_names[0])
    iterate_doc(data, zone)

def iterate_doc(data, zone):
    for name, values in data.iterrows():
        cpus = values["cpus"]
        memory = values["memory"]

        if not pandas.isna(cpus) and not pandas.isna(memory):
            lookup_instace(cpus, memory, zone)

def lookup_instace(guestCpus, memoryMb, zone):
    print("Matching compute configuration with {} vCPUs and {} MB memory to GCE machine types in '{}'".format(guestCpus, memoryMb, zone))

    cursor = db.cursor()
    cursor.execute("SELECT name FROM MachineTypes WHERE guestCpus = ? AND memoryMb = ? AND zone LIKE ? ORDER BY guestCpus, memoryMb LIMIT 0, 1", (guestCpus, memoryMb, "{}%".format(zone)))
    print(cursor.fetchall())

def download_machineTypes(project_id):
    print("Downloading machine types for project '{}'".format(project_id))
    compute = googleapiclient.discovery.build('compute', 'v1')
    types = compute.machineTypes().aggregatedList(project=project_id, maxResults=4000).execute()

    with open(name_file, "w+") as f:
        print("Writing machine types to '{}'".format(name_file))
        f.write(json.dumps(types))

def load_machineTypes():
    with open(name_file, "r") as f:
        types = json.load(f)

    clean_machineTypes()

    print("Write machine types to database")
    for key, value in types["items"].items():
        if "machineTypes" in value.keys():
            write_machineTypes(value["machineTypes"])

def clean_machineTypes():
    print("Removing machine types from database")
    cursor = db.cursor()
    cursor.execute("DELETE FROM MachineTypes")
    db.commit()

def write_machineTypes(machine_types):
    cursor = db.cursor()

    types = []
    for machine_type in machine_types:
        item = (machine_type["name"], machine_type["description"], machine_type["guestCpus"], machine_type["memoryMb"], machine_type["imageSpaceGb"], machine_type["maximumPersistentDisks"], machine_type["maximumPersistentDisksSizeGb"], machine_type["zone"])
        types.append(item)

    cursor.executemany("INSERT INTO MachineTypes VALUES (?, ?, ?, ?, ?, ?, ?, ?)", types)
    db.commit()

def setup_db():
    cursor = db.cursor()
    cursor.execute("CREATE TABLE IF NOT EXISTS MachineTypes ("
        "name TEXT, "
        "description TEXT, "
        "guestCpus INTEGER, "
        "memoryMb INTEGER, "
        "imageSpaceGb INTEGER, "
        "maximumPersistentDisks INTEGER, "
        "maximumPersistentDisksSizeGb INTEGER, "
        "zone TEXT"
        ")")

main()