#!/usr/bin/env nextflow

/*
vim: syntax=groovy
-*- mode: groovy;-*-
*/

log.info "--------------------------"
log.info "DBNL Pipeline"
log.info "--------------------------"

def env = System.getenv()

params.virtualenv =  env.containsKey('VIRTUAL_ENV') ? env['VIRTUAL_ENV'] : ""
params.language = "nld"
params.extension = "xml"
params.outputdir = "dbnl_output"
params.skip = "mcpa"
params.oztids = "data/dbnl_ozt_ids.txt"
params.preservation = "/dev/null"
params.rules = "/dev/null"
params.entitylinking = ""; //Methods correspond to FoliaEntity.exe -m option, if empty, entity linking is disabled
params.entitylinkeroptions = ""; //Extra options for entity linker (such as -u, include the actual option flags in string"
params.metadatadir = "";
params.mode = "both";
params.foliainput = false

if (params.containsKey('help') || !params.containsKey('inputdir') || !params.containsKey('dictionary') || !params.containsKey('inthistlexicon')) {
    log.info "Usage:"
    log.info "  dbnl.nf [OPTIONS]"
    log.info ""
    log.info "Mandatory parameters:"
    log.info "  --mode [modernize|simple|both]"
    log.info "  --inputdir DIRECTORY     Input directory (TEI documents)"
    log.info "  --dictionary FILE        Modernisation dictionary"
    log.info "  --inthistlexicon FILE    INT Historical Lexicon dump file"
    log.info""
    log.info "Optional parameters:"
    log.info "  --mode [modernize|simple|both]  Do modernisation, process original content immediately (simple), or both? Default: both"
    log.info "  --foliainput             Input is tokenised FoLiA instead of TEI (bypasses part of the pipeline)"
    log.info "  --inthistlexicon FILE    INT historical lexicon"
    log.info "  --preservation FILE      Preservation lexicon (list of words that will not be processed by the rules)"
    log.info "  --rules FILE             Substitution rules"
    log.info "  --outputdir DIRECTORY    Output directory (FoLiA documents)"
    log.info "  --metadatadir DIRECTORY  Directory including JSON metadata (one file matching each input document)"
    log.info "  --language LANGUAGE      Language"
    log.info "  --oztids FILE            List of IDs for DBNL onzelfstandige titels (default: data/dbnl_ozt_ids.txt)"
    log.info "  --extension STR          Extension of TEI documents in input directory (default: xml)"
    log.info "  --skip=[mptncla]         Skip Tokenizer (t), Lemmatizer (l), Morphological Analyzer (a), Chunker (c), Multi-Word Units (m), Named Entity Recognition (n), or Parser (p)"
    log.info "  --virtualenv PATH        Path to Virtual Environment to load (usually path to LaMachine)"
    log.info "  --entitylinking METHODS  Do entity linking according to specified methods (see -m option of FoliaEntity) (DISABLED BY DEFAULT!)"
    log.info "  --entitylinkeroptions X  Extra options to pass to entity linker"
    exit 2
}


try {
    if (!nextflow.version.matches('>= 0.25')) { //ironically available since Nextflow 0.25 only
        log.error "Requires Nextflow >= 0.25, your version is too old"
        exit 2
    }
} catch(ex) {
    log.error "Requires Nextflow >= 0.25, your version is too old"
    exit 2
}

if (!params.foliainput) {
    teidocuments = Channel.fromPath(params.inputdir+"/**." + params.extension)

    oztfile = Channel.fromPath(params.oztfile)

    process teiAddIds {
        //Add ID attribute to TEI file

        input:
        each file(teidocument) from teidocuments
        file oztfile
        val baseDir

        output:
        file "${teidocument.simpleName}.ids.xml" into tei_id_documents

        script:
        """
        ${baseDir}/scripts/dbnl/teiAddIds.pl ${teidocument} ${oztfile}
        """
    }

    process tei2folia {
        //Extract text from TEI documents and convert to FoLiA

        input:
        file teidocument from tei_id_documents

        output:
        file "${teidocument.simpleName}.folia.xml" into foliadocuments

        script:
        """
        ${baseDir}/scripts/dbnl/teiExtractText.pl ${teidocument} > tmp.xml

        #Delete any empty paragraphs (invalid FoLiA)
        ${baseDir}/scripts/dbnl/frogDeleteEmptyPs.pl tmp.xml > tmp2.xml

        #the generated FoLiA may not be valid due to multiple heads in a single section, eriktks post-corrected this with the following script:
        ${baseDir}/scripts/dbnl/frogHideHeads.pl tmp2.xml NODECODE > ${teidocument.simpleName}.folia.xml

        """
    }

    if (params.metadatadir != "") {
        process addmetadata {
            input:
            file inputdocument from foliadocuments
            val virtualenv from params.virtualenv
            val metadatadir from params.metadatadir

            output:
            file "${inputdocument.simpleName}.withmetadata.folia.xml" into foliadocuments2

            script:
            """
            set +u
            if [ ! -z "${virtualenv}" ]; then
                source ${virtualenv}/bin/activate
            fi
            set -u

            python ${baseDir}/scripts/dbnl/addmetadata.py ${inputdocument} ${inputdocument.simpleName}.withmetadata.folia.xml ${metadatadir}
            """
        }
    } else {
        foliadocuments.set { foliadocuments2 }
    }

    process tokenize_ucto {
        //tokenize the text

        input:
        file inputdocument from foliadocuments2
        val language from params.language
        val virtualenv from params.virtualenv

        output:
        file "${inputdocument.simpleName}.tok.folia.xml" into foliadocuments_tokenized

        script:
        """
        set +u
        if [ ! -z "${virtualenv}" ]; then
            source ${virtualenv}/bin/activate
        fi
        set -u

        ucto -L ${language} -X -F ${inputdocument} ${inputdocument.simpleName}.tok.folia.xml
        """
    }

    //foliadocuments_tokenized.subscribe { println it }
} else {
    foliadocuments_tokenized = Channel.fromPath(params.inputdir+"/**.folia.xml")
}


//split the tokenized documents into batches of 1000 each, fork into two channels
foliadocuments_tokenized
    .buffer( size: 1000, remainder: true)
    .collect()
    .into { foliadocuments_batches_tokenized1; foliadocuments_batches_tokenized2 }

if ((params.mode == "both") || (params.mode == "simple")) {

    process frog_original {
        //Linguistic enrichment on the original text of the document (pre-modernization)
        //Receives multiple input files in batches

        if ((params.entitylinking == "") && (params.mode == "simple")) {
            publishDir params.outputdir, mode: 'copy', overwrite: true
        }

        input:
        file foliadocuments from foliadocuments_batches_tokenized1 //foliadocuments is a collection/batch for multiple files
        val skip from params.skip
        val virtualenv from params.virtualenv

        output:
        file "*.frogoriginal.folia.xml" into foliadocuments_frogged_original mode flatten

        script:
        """
        set +u
        if [ ! -z "${virtualenv}" ]; then
            source ${virtualenv}/bin/activate
        fi
        set -u

        opts=""
        if [ ! -z "$skip" ]; then
            opts="--skip=${skip}"
        fi

        #move input files to separate staging directory
        mkdir input
        mv *.folia.xml input/

        #output will be in cwd
        frog \$opts --xmldir "." --threads ${task.cpus} --testdir input/ -x

        #set proper output extension
        mmv "*.folia.xml" "#1.frogoriginal.folia.xml"
        """
    }

}


//foliadocuments_frogged_original.subscribe { println "DBNL debug pipeline output document: " + it.name }
if ((params.mode == "both") || (params.mode == "modernize")) {

    //add the necessary input files to each batch
    foliadocuments_batches_tokenized2
        .map { batchfiles -> tuple(batchfiles, file(params.dictionary), file(params.preservation), file(params.rules), file(params.inthistlexicon)) }
        .set { foliadocuments_batches_withdata }

    process modernize_and_frog {
        //translate the document to contemporary dutch for PoS tagging AND run Frog on it
        //adds an extra <t class="contemporary"> layer

        if ((params.entitylinking == "") && (params.mode == "modernize")) {
            publishDir params.outputdir, mode: 'copy', overwrite: true
        }

        input:
        set file(inputdocuments), file(dictionary), file(preservationlexicon), file(rulefile), file(inthistlexicon) from foliadocuments_batches_withdata
        val skip from params.skip
        val virtualenv from params.virtualenv

        output:
        file "*.frogmodernized.folia.xml" into foliadocuments_frogged_modernized mode flatten

        script:
        """
        set +u
        if [ ! -z "${virtualenv}" ]; then
            source ${virtualenv}/bin/activate
        fi
        set -u

        opts=""
        if [ ! -z "$skip" ]; then
            opts="--skip=${skip}"
        fi

        mkdir modernization_work
        mv *.folia.xml modernization_work

        #if [ ! -z "${inthistlexicon}" ]; then
        #    extraopts="-H ${inthistlexicon}"
        #else
        #    extraopts=""
        #fi
        FoLiA-wordtranslate --outputclass contemporary -t ${task.cpus} -d ${dictionary} -p ${preservationlexicon} -r ${rulefile} -H ${inthistlexicon} modernization_work/

        mkdir froginput
        mv *.translated.folia.xml froginput/

        #output will be in cwd
        frog \$opts -x --xmldir "." --threads=${task.cpus} --textclass contemporary --testdir froginput/

        #set proper output extension
        mmv "*.translated.folia.xml" "#1.frogmodernized.folia.xml"
        """
    }


    if (params.mode == "both") {

        // transform [file] -> [(basename, file)]
        foliadocuments_frogged_original
            .map { file -> [file.simpleName, file] }
            .set { foliadocuments_frogged_original2 }

        // transform [file] -> [(basename, file)]
        foliadocuments_frogged_modernized
            .map { file -> [file.simpleName, file] }
            .set { foliadocuments_frogged_modernized2 }

        //now combine the two channels on basename: [ (basename, modernizedfile, originalfile) ]
        foliadocuments_frogged_modernized2
            .combine(foliadocuments_frogged_original2, by: 0) //0 refers to first input tuple element (basename)
            .set { foliadocuments_pairs }

        process merge {
            //merge the modernized annotations with the original ones, the original ones will be included as alternatives

            if (params.entitylinking == "") {
                publishDir params.outputdir, mode: 'copy', overwrite: true
            }

            input:
            set val(basename), file(modernfile), file(originalfile) from foliadocuments_pairs
            val skip from params.skip
            val virtualenv from params.virtualenv

            output:
            file "${basename}.folia.xml" into foliadocuments_merged

            script:
            """
            set +u
            if [ ! -z "${virtualenv}" ]; then
                source ${virtualenv}/bin/activate
            fi
            set -u

            foliamerge -a ${modernfile} ${originalfile} > ${basename}.folia.xml
            """
        }

    } else {
        //modernize mode
        foliadocuments_frogged_modernized
            .set { foliadocuments_merged }
    }
} else {
    //simple mode

    foliadocuments_frogged_original
        .set { foliadocuments_merged }

}

if (params.entitylinking != "") {
    process entitylinker {
        publishDir params.outputdir, mode: 'copy', overwrite: true

        input:
        file document from foliadocuments_merged
        val virtualenv from params.virtualenv
        val methods from params.entitylinking
        val extraoptions from params.entitylinkeroptions

        output:
        file "${document.simpleName}.linked.folia.xml" into entitylinker_output


        script:
        """
        set +u
        if [ ! -z "${virtualenv}" ]; then
            source ${virtualenv}/bin/activate
            rootpath=${virtualenv}
        else
            rootpath=/opt
        fi
        set -u

        mkdir out
        \$rootpath/foliaentity/FoliaEntity.exe -w -m ${methods} ${extraoptions} -i ${document} -o out/
        zcat out/\$(basename ${document}).gz > ${document.simpleName}.linked.folia.xml
        """
    }

    entitylinker_output.subscribe { println "DBNL pipeline output document written to " +  params.outputdir + "/" + it.name }
} else {
    //for all modes
    foliadocuments_merged.subscribe { println "DBNL pipeline output document written to " +  params.outputdir + "/" + it.name }
}
