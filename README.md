# EXPORT-TS

A tool to export a blog's templates as a template set.

Basic Usage:

    cd /PATH/TO/MT/
    perl ./tools/export-ts --blog=1 --id="MyTemplateSet"

## Requirements

* MT4.x

## Description

`export-ts` is a tool to export a blog's templates to a template set (a plugin) that can be installed elsewhere.


## Installation

1. Place this script inside your Movable Type tools directory:

    /PATH/TO/MT/tools/

2. Update file permissions to 775

    chmod 775 /PATH/TO/MT/tools/export-ts


## Options

The following options are available:

### blog

(required) The Blog ID to export templates from

### id

The ID to be used for the creation of the resulting plugin. This is also used to determine the output directory for related files.

### name

The name to be used for the creation of the resulting plugin. This is also used to determine the output directory for related files.

### version

The version string to be used for the creation of the resulting plugin.

### static

The path to the directory containing your mt-static files for this template set. It must be a relative path from your mt-static folder.

### key

The MT::PluginData key of the resulting template set.

### out

The path to a directory in which you wish to output the template set's files. (default: current directory)

### verbose

Show verbose messages.

## Usage

From the command line, one would type:

    cd /PATH/TO/MT/
    chmod a+x tools/export-ts
    perl ./tools/export-ts --blog=1 --id=MySet --name="My Template Set" --version=3 --out="template-sets"

This would result in the following directories being created:

    /PATH/TO/MT/template-sets/
        MySet-3/
            plugins/
                MySet/
                    config.yaml
                    templates/*
            mt-static/
                plugins/
                    MySet/*

You should then be able to zip up the MySet directory or simply install as you would install any other plugin.

Once installed you can use the "refresh blog templates" action in the sidebar of the the Manage Templates screen (Design > Templates). Once templates are refreshed, rebuild the blog.
