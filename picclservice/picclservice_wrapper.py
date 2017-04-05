#!/usr/bin/env python
#-*- coding:utf-8 -*-

#CLAM wrapper script for PICCL

#This script will be called by CLAM and will run with the current working directory set to the specified project directory

#This wrapper script uses Python and the CLAM Data API.
#We make use of the XML settings file that CLAM outputs, rather than
#passing all parameters on the command line.


#If we run on Python 2.7, behave as much as Python 3 as possible
from __future__ import print_function, unicode_literals, division, absolute_import

#import some general python modules:
import sys
import os
import glob
import shutil

#import CLAM-specific modules. The CLAM API makes a lot of stuff easily accessible.
import clam.common.data
import clam.common.status

#When the wrapper is started, the current working directory corresponds to the project directory, input files are in input/ , output files should go in output/ .

#make a shortcut to the shellsafe() function
shellsafe = clam.common.data.shellsafe

#this script takes three arguments from CLAM: $DATAFILE $STATUSFILE $OUTPUTDIRECTORY
#(as configured at COMMAND= in the service configuration file, there you can
#reconfigure which arguments are passed and in what order.
datafile = sys.argv[1]
statusfile = sys.argv[2]
inputdir = sys.argv[3]
outputdir = sys.argv[4]
piccldataroot = sys.argv[5]

#If you make use of CUSTOM_FORMATS, you need to import your service configuration file here and set clam.common.data.CUSTOM_FORMATS
#Moreover, you can import any other settings from your service configuration file as well:

#from yourserviceconf import CUSTOM_FORMATS

#Obtain all data from the CLAM system (passed in $DATAFILE (clam.xml)), always pass CUSTOM_FORMATS as second argument if you make use of it!
clamdata = clam.common.data.getclamdata(datafile)

#You now have access to all data. A few properties at your disposition now are:
# clamdata.system_id , clamdata.project, clamdata.user, clamdata.status , clamdata.parameters, clamdata.inputformats, clamdata.outputformats , clamdata.input , clamdata.output

clam.common.status.write(statusfile, "Starting...")


#=========================================================================================================================

lang = clamdata['lang']
if lang == 'deu_frak': lang = 'deu' #Fraktur German is german for all other intents and purposes

datadir = os.path.join(piccldataroot,'data','int',lang)
if not os.path.exists(datadir):
    errmsg = "ERROR: Unable to find data files for language '" + lang + "' in path " + piccldataroot
    clam.common.status.write(statusfile, errmsg,0) # status update
    print(errmsg,file=sys.stderr)
    sys.exit(4)

#loop over all data files and copy (symlink actually to save diskspace and time) to the current working directory (project dir)
for f in glob.glob(datadir + '/*'):
    if f.split('.')[-1] == 'dict':
        if os.path.exists('lexicon.lst'): os.unlink('lexicon.lst') #remove any existing
        os.symlink(f, 'lexicon.lst')
    if f.split('.')[-1] == 'chars':
        if os.path.exists('alphabet.lst'): os.unlink('alphabet.lst') #remove any existing
        os.symlink(f, 'alphabet.lst')
    if f.split('.')[-1] == 'confusion':
        if os.path.exists('confusion.lst'): os.unlink('confusion.lst') #remove any existing
        os.symlink(f, 'confusion.lst')

if not os.path.exists('lexicon.lst'):
    errmsg = "ERROR: Unable to find lexicon file for language '" + lang + "' in path " + piccldataroot
    clam.common.status.write(statusfile, errmsg,0) # status update
    print(errmsg,file=sys.stderr)
    sys.exit(4)
if not os.path.exists('alphabet.lst'):
    errmsg = "ERROR: Unable to find alphabet file for language '" + lang + "' in path " + piccldataroot
    clam.common.status.write(statusfile, errmsg,0) # status update
    print(errmsg,file=sys.stderr)
    sys.exit(4)
if not os.path.exists('confusion.lst'):
    errmsg = "ERROR: Unable to find confusion file for language '" + lang + "' in path " + piccldataroot
    clam.common.status.write(statusfile, errmsg,0) # status update
    print(errmsg,file=sys.stderr)
    sys.exit(4)


#Derive input type from used inputtemplate
inputtype = ''
for inputfile in clamdata.input:
   inputtemplate = inputfile.metadata.inputtemplate
   if inputtemplate == 'pdfimages':
        inputtype = 'pdfimages'
   elif inputtemplate == 'tif':
        inputtype == 'tif'
   elif inputtemplate == 'jpg':
        inputtype == 'jpg'
   elif inputtemplate == 'png':
        inputtype == 'png'
   elif inputtemplate == 'gif':
        inputtype == 'gif'
   elif inputtemplate == 'foliaocr':
        inputtype == 'foliaocr'

if not inputtype:
    errmsg = "ERROR: Unable to deduce input type on the basis of input files (should not happen)!"
    clam.common.status.write(statusfile, errmsg,0) # status update
    print(errmsg,file=sys.stderr)
    sys.exit(5)

if inputtype == 'foliaocr':
    ticclinputdir = "." #FoLiA input files provided directly, no need to run OCR pipeline
else:
    clam.common.status.write(statusfile, "Running OCR Pipeline",1) # status update
    os.system("nextflow run LanguageMachines/PICCL/ocr.nf --inputdir " + shellsafe(inputdir,'"') + " --outputdir ocr_output --inputtype " + shellsafe(inputtype,'"') + " --language " + shellsafe(clamdata['lang'],'"') +" -with-trace >&2" ); #use original clamdata['lang'] (may be deu_frak)

    #Print Nextflow trace information to stderr so it ends up in the CLAM error.log and is available for inspection
    print("OCR pipeline trace summary",file=sys.stderr)
    print("-------------------------------",file=sys.stderr)
    print(open('trace.txt','r',encoding='utf-8').read(), file=sys.stderr)
    ticclinputdir = "ocr_output"

clam.common.status.write(statusfile, "Running TICCL Pipeline",50) # status update
os.system("nextflow run LanguageMachines/PICCL/ticcl.nf --inputdir " + ticclinputdir + " --outputdir " + shellsafe(outputdir,'"') + " --lexicon lexicon.lst --alphabet alphabet.lst --charconfus confusion.lst --clip " + shellsafe(clamdata['rank']) + " --distance " + shellsafe(clamdata['distance']) + " --clip " + shellsafe(clamdata['rank']) + " -with-trace >&2"  );

#Print Nextflow trace information to stderr so it ends up in the CLAM error.log and is available for inspection
print("TICCL pipeline trace summary",file=sys.stderr)
print("-------------------------------",file=sys.stderr)
print(open('trace.txt','r',encoding='utf-8').read(), file=sys.stderr)


#cleanup
shutil.rmtree('work')

#A nice status message to indicate we're done
clam.common.status.write(statusfile, "All done!",100) # status update

sys.exit(0) #non-zero exit codes indicate an error and will be picked up by CLAM as such!
