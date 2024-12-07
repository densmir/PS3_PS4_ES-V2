#
# This is a Shiny web application. You can run the application by clicking
# the 'Run App' button above.
#
# Find out more about building applications with Shiny here:
#
#    http://shiny.rstudio.com/
#

# App for publish
library(shiny)
library(fmsb)
library(tidyverse)
library(lpSolve)
library(readxl)
library(bigrquery)
library(aws.s3)
library(readxl)
library(glue)
library(lpSolve)
library(plotly)
library(mice)


# Define UI
ui <- fluidPage(
  h1("Early Silage advancements"),
  
  tabsetPanel(
    tabPanel(
      title = "Inputs",
      sidebarLayout(
        sidebarPanel(
          tabsetPanel(
            tabPanel(
              "Selection options",
              h2("Selection options"),
              selectInput("market", "Market",
                          choices = c("Early Silage", "Early Silage SSC"),
                          multiple = FALSE,
                          selected = "Early Silage"),
              selectInput("submarket", "Sub-Market",
                          choices = c("ME1", "ME2", "ME3", "ME4", "ME5"),
                          multiple = TRUE,
                          selected = "ME1"),
              selectInput("stage", "Stage",
                          choices = c("PS1", "PS2", "PS3", "PS4"),
                          multiple = TRUE,
                          selected = "PS4"),
              textInput("year", "Year", value = "2024")
            ),
            tabPanel(
              "Allocation",
              h2("Criteria"),
              numericInput("advancements", "Nbr of adv", value = 42, min = 1, max = 200),
              numericInput("binning", "Binning factor", value = 5, min=2, max = 10),
              h3("Market value"),
              sliderInput("mk_sd", "Silage double:", min = 0, max = 1, value = 0.45, step = 0.01),
              sliderInput("mk_sq", "Silage quality:", min = 0, max = 1, value = 0.35, step = 0.01),
              sliderInput("mk_sv", "Silage volume:", min = 0, max = 1, value = 0.2, step = 0.01)
            )
          ) 
        ),
        mainPanel(
          textInput("blup", "HBlup report", value = "CE24B_0054"),
          fileInput("hybrids", "Upload list of hybrids"),
          tableOutput("hybrids"),
          downloadButton("downloadData", "Download Entry list Exemple"),
          actionButton("mybutton", "Run Script")
        )
      )
    ),
    
    tabPanel(
      title = "Outputs",
      selectInput("selected_name", "Select Hybrid:", choices = NULL, multiple = TRUE)  # Initialize with NULL
      ,
      titlePanel("Advancements"),
      downloadButton("downloadoutput", "Download advancements"),
      DT::dataTableOutput("finaltable"),
      tabsetPanel(
        tabPanel("Correlation trait vs index",
                 plotlyOutput("plot", height = "700px")),
        tabPanel("Hybrids head to head",
                 plotOutput("hybrids_plot", height = "500px")),
        tabPanel("Hybrids - indexes",
                 plotOutput("hybrids_indexes", height = "500px"))
      )
    )
  )
)



# Define server logic
server <- function(input, output, session) {
  
  entry_list_init <- reactive({
    req(input$hybrids)  
    read.csv(input$hybrids$datapath, stringsAsFactors = FALSE)
  }) 
  
  
  # Use the existing data frame
  observe({
    data  = entry_list_init()
    # Update the selectInput choices based on the Name column of the existing data frame
    updateSelectInput(session, "selected_name", choices = data$hybrid)
  })
  
  
  # for input Ex file
  Ex_Entry_list_hybrids <- as.data.frame(tribble(
    ~hybrid, ~S0, ~S1, ~S2, ~type,
    "EV3322", 1, 1, 0, "PS4"
  ))
  
  output$hybrids <- renderTable({
    req(input$hybrids)
    data <- read.csv(input$hybrids$datapath, stringsAsFactors = FALSE)
    head(data, n = 5)
  })
  
  output$downloadData <- downloadHandler(
    filename = function() {
      "Ex_Hybrid_entry_list.csv"
    },
    content = function(file) {
      write.csv(Ex_Entry_list_hybrids, file, row.names = FALSE)
    }
  )
  observeEvent(input$mybutton, {  
    
    # Change the report name after each year
    report_name <- reactive({
      input$blup
    })
    
    #### Options ####
    market <- reactive({
      input$market
    })
    
    sub_market <- reactive({
      input$submarket
    })
    
    stage <- reactive({
      input$stage
    })
    
    year <- reactive({
      input$year
    })
    
    allocation = reactive({
      input$advancements
    })
    
    Ealy_INDEX_BLUP = read.csv("Early_INDEX_BLUP.csv")
    
    entry_list_md <- Ealy_INDEX_BLUP %>%
      spread(trait, num_value) %>%
      filter(LINE_NAME %in% entry_list_init()$hybrid) %>%
      rename(hybrid = LINE_NAME) %>%
      rename_all(~ gsub("_BLUP", "", .x, fixed = TRUE))
    # debugging
    #browser()
    # To format data columns to numeric
    entry_list_md[,2:ncol(entry_list_md)] <- sapply(entry_list_md[2:ncol(entry_list_md)],as.numeric)
    
    # imputation for missing values using pmm
    entry_list_imp = mice(entry_list_md[,2:ncol(entry_list_md)], m = 5, method = c("pmm"), maxit = 20)
    entry_list_imp = complete(entry_list_imp, 1)
    entry_list_imp$hybrid = entry_list_md$hybrid
    entry_list_imp = select(entry_list_imp, hybrid, everything())
    names(entry_list_imp)[1] <- "hybrid"
    
    material_type <- "Hybrid"
    het_pattern   <- c("FxD")
    
    # replace the missing values HBLUP with 0
    # out_file_name <- paste0(market, "_", stage, "_", material_type, "_", het_pattern, "_OTA_",Sys.Date() ,".csv")
    
    # Market size par product concept
    # mkt_sd <- 0.45
    # mkt_sq <- 0.35
    # mkt_sv <- 0.2
    
    # repartition des avancements par product concept
    
    br_effort_sd <- round(allocation()*input$mk_sd,0) 
    br_effort_sq <- round(allocation()*input$mk_sq,0)
    br_effort_sv <- round(allocation()*input$mk_sv,0)
    
    over_alloc <- 0
    
    binning <- input$binning
    
    # Normalization
    entry_list_n <- as.data.frame(scale(entry_list_imp[,2:ncol(entry_list_imp)], center = T, scale = T)) #normalization
    entry_list_n <-  cbind(entry_list_imp$hybrid,entry_list_n)
    names(entry_list_n)[1] <- "hybrid"
    
    #### Set up coefficient ####
    
    #ecowt <- c(1,1,1,-2,-1,-2,1,1,1,1,1,1,-1.5,-1,-2) # original
    # Modif done from original
    # STYLD_BE: 1 -> 1.5
    # GYMSE: 1 -> 1.5
    # RTLP : -1 -> -2 -> -4
    # STLP : -1 -> -2
    # SPAR : 1 -> -2 then -2 to -1.5 -> -2
    # GASPOT : 1 -> 2 then 2 -> 1.5 -> 1
    # PHT : 1 -> 2 then 2 -> 1
    # EHT : -2 -> -1
    # NDF: 1 -> 0
    # STAS : 1 -> 2 then back to 1
    ecowt <- c(1.5,1,1.5,-4,-2,-1,2,2,1,-2,0,1,-1.5,-1,-1,-1,-1,-1,-1,1,1,-1,1,1,1) #economic weight
    coeff_es <- as.data.frame(ecowt)
    rownames(coeff_es) <- c("STYLD_BE","SYDME","GYMSE","RTLP","STLP","EHT","DCW","STAS_BE","PHT","SPAR",
                            "NDF","GASPOT","S50D","EVG","INT","RTLP_NL","STLP_NL","EHT_NL","INT_NL",
                            "STAS_BE_NL","GASPOT_NL","SPAR_NL","DCW_NL","GYMSE_NL","STYLD_NL") 
    
    colnames(coeff_es)[1] <- "coeff_es"
    
    #Question: Coeff for the sub-indexes: how did you determine these indexes ?
    coeff_si = as.data.frame(tribble(
      ~e, ~sd, ~sq, ~sv,
      "perf",  0.35, 0.35,0.28,
      "agro", 0.25, 0.15,0.1,
      "feed", 0.03,0.25,0.05,
      "look",0.05,0,0.3,
      "earliness",0.05,0.08,0.03,
      "biogas", 0,0,0.1,
    ))
    
    rownames(coeff_si) = coeff_si[,1]
    coeff_si$e = NULL
    
    #### 03.2 - Compute indexes ####  
    # Compute the NL trait
    
    #### 03.2 - Compute indexes ####  
    # Compute the NL trait
    
    # Parameters
    
    
    thr_T <- as.data.frame(c(0,0,0,0,0.5,0.5,0,0,0,0.5)) #threshold
    thr_b <- as.data.frame(c(1,1,0,0,0,0,1,1,1,1)) # utilisation pour les caluls de transformation lineaire
    thr_c <- as.data.frame(c(-5,-5,5,5,5,5,5,10,3,-5)) # STAS and GASPOT are neg since we want to get rid of the worse --> coeficient
    thr_d <- as.data.frame(c(2,2,1.5,1.5,1,1,2,1,1,2)) # --> puissance
    
    thr_nl <- cbind(thr_T,thr_b,thr_c,thr_d)
    rownames(thr_nl) <- c("biogas","stas","rtlp","stlp","eht","int","spar","dcw","gymse","styld")
    
    colnames(thr_nl) <- c("T","b","c","d")
    
    # Compute NL traits: 
    # si superieur ou égale au seuil; inferieur --> transformation non lineaire. Augmenter les pénalités. 
    #Transformation non linéaire - certains traits. Augmenter les pénalités pour les traits qui sont en desous des thresholds
    entry_list_nl <- entry_list_n %>%
      mutate(GASPOT_NL = ifelse(GASPOT >= thr_nl[1,1], 
                                thr_nl[1,2] * (GASPOT - thr_nl[1,1]),
                                (thr_nl[1,3] * (GASPOT - thr_nl[1,1]) ^ thr_nl[1,4]) 
                                + thr_nl[1,2] * (GASPOT - thr_nl[1,1]))) %>%
      mutate(STAS_NL = ifelse(STAS_BE >= thr_nl[2,1], 
                              thr_nl[2,2] * (STAS_BE - thr_nl[2,1]),
                              (thr_nl[2,3] * (STAS_BE - thr_nl[2,1]) ^ thr_nl[2,4]) 
                              + thr_nl[2,2] * (STAS_BE - thr_nl[2,1]))) %>%
      mutate(RTLP_NL = ifelse(RTLP <= thr_nl[3,1], 
                              thr_nl[3,2] * (RTLP - thr_nl[3,1]),
                              (thr_nl[3,3] * (RTLP - thr_nl[3,1]) ^ thr_nl[3,4]) 
                              + thr_nl[3,2] * (RTLP - thr_nl[3,1]))) %>%
      mutate(STLP_NL = ifelse(STLP < thr_nl[4,1], 
                              thr_nl[4,2] * (STLP - thr_nl[4,1]),
                              (thr_nl[4,3] * (STLP - thr_nl[4,1]) ^ thr_nl[4,4]) 
                              + thr_nl[4,2] * (STLP - thr_nl[4,1]))) %>%
      mutate(EHT_NL = ifelse(EHT <= thr_nl[5,1], 
                             thr_nl[5,2] * (EHT - thr_nl[5,1]),
                             (thr_nl[5,3] * (EHT - thr_nl[5,1]) ^ thr_nl[5,4]) 
                             + thr_nl[5,2] * (EHT - thr_nl[5,1]))) %>%
      mutate(INT_NL = ifelse(INT <= thr_nl[6,1], 
                             thr_nl[6,2] * (INT - thr_nl[6,1]),
                             (thr_nl[6,3] * (INT - thr_nl[6,1]) ^ thr_nl[6,4]) 
                             + thr_nl[6,2] * (INT - thr_nl[6,1]))) %>%
      mutate(SPAR_NL = ifelse(SPAR <= thr_nl[7,1], 
                              thr_nl[7,2] * (SPAR - thr_nl[7,1]),
                              (thr_nl[7,3] * (SPAR - thr_nl[7,1]) ^ thr_nl[7,4]) 
                              + thr_nl[7,2] * (SPAR - thr_nl[7,1]))) %>%
      mutate(DCW_NL = ifelse(DCW >= thr_nl[8,1], 
                             thr_nl[8,2] * (DCW - thr_nl[8,1]),
                             (thr_nl[8,3] * (DCW - thr_nl[8,1]) ^ thr_nl[8,4]) 
                             + thr_nl[8,2] * (DCW - thr_nl[8,1]))) %>%
      mutate(GYMSE_NL = ifelse(GYMSE >= thr_nl[9,1], 
                               thr_nl[9,2] * (GYMSE - thr_nl[9,1]),
                               (thr_nl[9,3] * (GYMSE - thr_nl[9,1]) ^ thr_nl[9,4]) 
                               + thr_nl[9,2] * (GYMSE - thr_nl[9,1]))) %>%
      mutate(STYLD_NL = ifelse(STYLD_BE >= thr_nl[10,1], 
                               thr_nl[10,2] * (STYLD_BE - thr_nl[10,1]),
                               (thr_nl[10,3] * (STYLD_BE - thr_nl[10,1]) ^ thr_nl[10,4]) 
                               + thr_nl[10,2] * (STYLD_BE - thr_nl[10,1]))) 
    
    # Normalize the data (with NL traits): renormalisation
    
    entry_list_nl_n <- as.data.frame(scale(entry_list_nl[,2:ncol(entry_list_nl)], center = T, scale = T))
    entry_list_nl_n <-  cbind(entry_list_n[,1],entry_list_nl_n)
    names(entry_list_nl_n)[1] <- "hybrid"
    # Sub indexes: 
    # At this point, we will always have two tables:
    # - "no number": un-normalized data, to compute the PC indexes 
    # - 02: normalized data, used tocompute the aggregated indexes  
    
    # avoir des product concept index
    entry_list_i <- entry_list_nl %>% # non normalized
      mutate(index_perf = coeff_es[25,1] * STYLD_NL +
               coeff_es[2,1] * SYDME +
               coeff_es[24,1] * GYMSE_NL) %>%
      mutate(index_agro = coeff_es[16,1] * RTLP_NL +
               coeff_es[17,1] * STLP_NL +
               coeff_es[18,1] * EHT_NL +
               coeff_es[19,1] * INT_NL) %>%
      mutate(index_feed = coeff_es[23,1] * DCW_NL +
               coeff_es[8,1] * STAS_BE) %>%          
      mutate(index_look = coeff_es[9,1] * PHT +
               coeff_es[22,1] * SPAR_NL) %>%
      mutate(index_biogas = coeff_es[20,1] * STAS_NL +
               coeff_es[21,1] * GASPOT_NL) %>%  
      mutate(index_early = coeff_es[13,1] * S50D +
               coeff_es[14,1] * EVG)
    
    # avoir des indexes globales
    entry_list_i_02 <- entry_list_nl_n %>% # normalized 
      mutate(index_perf = coeff_es[25,1] * STYLD_NL +
               coeff_es[2,1] * SYDME +
               coeff_es[24,1] * GYMSE_NL) %>%
      mutate(index_agro = coeff_es[16,1] * RTLP_NL +
               coeff_es[17,1] * STLP_NL +
               coeff_es[18,1] * EHT_NL +
               coeff_es[19,1] * INT_NL) %>%
      mutate(index_feed = coeff_es[23,1] * DCW_NL +
               coeff_es[8,1] * STAS_BE) %>%          
      mutate(index_look = coeff_es[9,1] * PHT +
               coeff_es[22,1] * SPAR_NL) %>%
      mutate(index_biogas = coeff_es[20,1] * STAS_NL +
               coeff_es[21,1] * GASPOT_NL) %>%  
      mutate(index_early = coeff_es[13,1] * S50D +
               coeff_es[14,1] * EVG)
    
    #Question: difference between product concept index and indexes globales?
    # Re norm the sub indexes (with 02 table):
    
    entry_list_iN <- entry_list_i_02 %>% 
      select(contains("index")) %>% 
      scale(., center = T, scale = T)
    
    entry_list_in <-  entry_list_i_02 %>% 
      select(-contains("index")) %>% 
      cbind(entry_list_iN)
    
    # Agregation stage 1 - per PC: 
    # agreger les indexes
    entry_list_pc <- entry_list_i %>% # non normalized
      mutate(index_sd = coeff_si[1,1] * index_perf + 
               coeff_si[2,1] * index_agro + 
               coeff_si[3,1] * index_feed + 
               coeff_si[4,1] * index_look + 
               coeff_si[5,1] * index_early +
               coeff_si[6,1] * index_biogas) %>%
      mutate(index_sq= coeff_si[1,2] * index_perf + 
               coeff_si[2,2] * index_agro + 
               coeff_si[3,2] * index_feed + 
               coeff_si[4,2] * index_look + 
               coeff_si[5,2] * index_early +
               coeff_si[6,2] * index_biogas) %>%
      mutate(index_sv = coeff_si[1,3] * index_perf + 
               coeff_si[2,3] * index_agro + 
               coeff_si[3,3] * index_feed + 
               coeff_si[4,3] * index_look + 
               coeff_si[5,3] * index_early +
               coeff_si[6,3] * index_biogas)
    #Question: why doing the same operation for normalized and non-normalized values?
    #Question: why do we need to normalize values after each operation? 
    entry_list_pc_02 <- entry_list_in %>% # normalized 
      mutate(index_sd = coeff_si[1,1] * index_perf + 
               coeff_si[2,1] * index_agro + 
               coeff_si[3,1] * index_feed + 
               coeff_si[4,1] * index_look + 
               coeff_si[5,1] * index_early +
               coeff_si[6,1] * index_biogas) %>%
      mutate(index_sq= coeff_si[1,2] * index_perf + 
               coeff_si[2,2] * index_agro + 
               coeff_si[3,2] * index_feed + 
               coeff_si[4,2] * index_look + 
               coeff_si[5,2] * index_early +
               coeff_si[6,2] * index_biogas) %>%
      mutate(index_sv = coeff_si[1,3] * index_perf + 
               coeff_si[2,3] * index_agro + 
               coeff_si[3,3] * index_feed + 
               coeff_si[4,3] * index_look + 
               coeff_si[5,3] * index_early +
               coeff_si[6,3] * index_biogas)
    
    # 2nd indexes normalization : 
    
    entry_list_pcN <- entry_list_pc_02 %>% 
      select(contains(c("index_sd","index_sq","index_sv"))) %>% 
      scale(., center = T, scale = T)
    
    entry_list_pcn <-  entry_list_pc_02 %>% 
      select(-contains(c("index_sd","index_sq","index_sv"))) %>% 
      cbind(entry_list_pcN)
    
    # Final agregation off all product concepts per hybrid:                     
    
    entry_list_pcf <- entry_list_pcn %>%                  
      mutate(index_agreg = input$mk_sd * index_sd + input$mk_sq * index_sq + input$mk_sv * index_sv)
    
    #### Make recommendations ####       
    # with Bin
    
    entry_list_r_3.12 <- entry_list_pc %>% 
      mutate(bin_sd = binning+1 - ntile(index_sd,binning)) %>% 
      mutate(bin_sq = binning+1 - ntile(index_sq,binning)) %>%
      mutate(bin_sv = binning+1 - ntile(index_sv,binning)) 
    
    entry_list_r_02_3.12 <- entry_list_pcf %>%
      mutate(bin_adv = binning+1 - ntile(index_agreg,binning))
    
    #### 03.4 - Evaluation ####  
    names(entry_list_r_3.12)[1] <- "hybrid"
    names(entry_list_r_02_3.12)[1] <- "hybrid"
    
    entry_list_inter <- entry_list_r_02_3.12[,c("hybrid",
                                                "index_agreg","bin_adv")]
    
    entry_list_final <- entry_list_r_3.12 %>% 
      left_join(entry_list_inter, by = c("hybrid" = "hybrid")) %>%
      select(-contains("reco"))
    
    # Re scale the index pc for more readability. NB if we use the normalized indexes from 02 tables
    # then we have a problem since the order is not the same  as there are different inputs due to the 
    # NL values with 0 and the normalized one wtih no 0.
    
    entry_list_final_N <- entry_list_final %>% 
      select(contains(c("index_sd","index_sq","index_sv"))) %>% 
      scale(., center = T, scale = T)
    
    entry_list_final_n <-  entry_list_final %>% 
      select(-contains(c("index_sd","index_sq","index_sv"))) %>% 
      cbind(entry_list_final_N)
    
    
    product_concepts <- c("index_sd","index_sq","index_sv")
    
    # Programation linéaire, lpSolve - EVA
    #### Prepare Data ####
    entry_list_final_nV2 = filter(entry_list_final_n, !is.na(bin_adv))
    
    m <- entry_list_final_nV2 %>%
      select(one_of(product_concepts)) %>%
      mutate( Non = 0) %>%
      as.matrix
    
    solution_col_names <- colnames(m) %>% paste(., "select", sep = "_")
    
    row_signs <- rep("<=", nrow(m))
    row_rhs   <- rep(1, nrow(m))
    
    total_selection_target <- allocation()
    n_drop                 <- nrow(m) - total_selection_target
    
    Target <- c(br_effort_sd,br_effort_sq,br_effort_sv)
    
    col_rhs   <- c(Target, n_drop)
    col_signs <- rep("=", length(col_rhs))
    
    #### Run algorithm  ####
    #Question: the function lp.transport - for linear Transportation Problem. how to handle missing data?
    
    opt_outcome_raw <- lp.transport(m,"max",row_signs,row_rhs,col_signs,col_rhs)$solution %>%
      as.data.frame
    
    colnames(opt_outcome_raw) <- solution_col_names 
    
    opt_outcome_raw$hybrid <- entry_list_final_nV2$hybrid
    
    #### Prepare output ####
    outcome <- entry_list_final_nV2  %>%
      left_join(opt_outcome_raw) 
    
    test <- solution_col_names[1:length(solution_col_names)-1]
    
    outcome$Advanced_by_OTA <- outcome %>% subset(select = test) %>% apply(1, sum) %>% as.logical
    
    # Pivot
    
    pivot_OTA <- outcome %>%
      group_by(Advanced_by_OTA) %>%
      summarize_if(is.numeric, mean, na.rm = TRUE)
    
    pivot_agreg <- outcome %>%
      group_by(bin_adv) %>%
      summarize_if(is.numeric, mean, na.rm = TRUE)
    
    mat_cor <- cor(outcome[,-1])
    # reshaping
    cor_df <- reshape2::melt(mat_cor, varnames = c("Trait1", "Trait2"), value.name = "Correlation")
    # probleme
    # Create a plot
    output$plot <- renderPlotly({
      ggplotly({
        ggplot(cor_df, aes(Trait1, Trait2, fill = Correlation)) +
          geom_tile() +
          viridis::scale_fill_viridis(discrete = FALSE, na.value = "white") +
          theme_minimal() +
          labs(title = "Correlation plot", fill = "Correlation") +
          theme(
            axis.text.x = element_text(angle = 90, vjust = 0.5, hjust = 1, size = 8),
            axis.title.y = element_text(size = 8),
            plot.title = element_text(hjust = 0.5)
          )
      })
    })
    
    
    Final_outcome <- reactive({
      data <- outcome
      return(data)
    })
    ### Attention!!! retravailler sur la selection des hybrides
    
    output$finaltable <- DT::renderDataTable({
      # Get the selected hybrids from the input
      selected_hybrids <- input$selected_name
      # Check if any hybrids are selected
      if (length(selected_hybrids) > 0) {
        filtered_data <- Final_outcome()[Final_outcome()$hybrid %in% selected_hybrids, ]
      } else {
        filtered_data <- Final_outcome()
      }
      DT::datatable(filtered_data)
    })
    
    output$downloadoutput <- downloadHandler(
      filename = function() {
        paste(Sys.Date(),market(),stage(), "Hybrid_advancements.csv", sep = "_")
      },
      content = function(file) {
        write.csv(outcome, file, row.names = FALSE)
      }
    )
    
    # spider plot
    colsdata <- c("DCW" , "EHT" , "PHT" , "EVG" ,"S50D", "GASPOT", "GYMSE", "INT", "RTLP","STLP","SPAR", "STAS_BE","STYLD_BE", "SYDME" )
    # function for spider plot
    create_radarchart <- function(data, color = "#00AFBB", 
                                  vlabels = colnames(data), vlcex = 0.7,
                                  caxislabels = NULL, title = NULL, ...){
      radarchart(
        data, axistype = 1,
        # Customize the polygon
        pcol = color, pfcol = scales::alpha(color, 0.5), plwd = 2, plty = 1,
        # Customize the grid
        cglcol = "grey", cglty = 1, cglwd = 0.8,
        # Customize the axis
        axislabcol = "grey", 
        # Variable labels
        vlcex = vlcex, vlabels = vlabels,
        caxislabels = caxislabels, title = title, ...
      )
    }
    
    
    #parameters for radar graph
    params = matrix(ncol = length(colsdata), nrow= 2) 
    params = as.data.frame(params)
    rownames(params) = c("Max", "Min")
    colnames(params) = colsdata
    
    # Defining the parameters of the spider plot
    
    params[1,] = apply(select(outcome, colsdata)[,colsdata],2,max)
    params[2,] = apply(select(outcome, colsdata)[,colsdata],2,min)
    
    # selection of hybrids to compare head to head
    values_hybrid <- reactive({
      selected <- input$selected_name  # Assuming this is your selectInput ID
      if (length(selected) > 0) {
        selected
      } else {
        # Default to the first 4 hybrids if none are selected
        outcome$hybrid[1:4]
      }
    })
    
    
    generate_spider_plot <- function(outcome, values_hybrid, colsdata, params, title = "Head to head") {
      # Filter and select data
      spider_plot <- outcome %>%
        filter(hybrid %in% values_hybrid) %>%
        select(colsdata)
      
      # Add params row to the data
      spider_plot <- rbind(params, spider_plot)
      
      # Number of colours in the palette
      no_of_colors <- length(values_hybrid)
      
      # Applying the rainbow function
      colorful_palette <- rainbow(no_of_colors)
      
      # Plot settings
      par(mar = c(5, 4, 6, 9), xpd = TRUE)
      
      # Create the radar chart
      create_radarchart(spider_plot, title = title, color = colorful_palette)
      
      # Add legend
      legend("topright", inset = c(0, 0), legend = values_hybrid, horiz = FALSE,
             bty = "n", pch = 20, col = colorful_palette,
             text.col = "black", cex = 1.2, pt.cex = 1.5)
    }
    
    # Render the spider plot
    output$hybrids_plot <- renderPlot({
      generate_spider_plot(outcome, values_hybrid(), colsdata, params)
    })
    # spider plot
    
    
    ## With indexes
    colsdata2 <- c("index_perf" , "index_agro" , "index_feed" , "index_look" ,"index_biogas", "index_early", "index_sd", "index_sq", "index_sv")
    # function for spider plot
    
    #parameters for radar graph
    params2 = matrix(ncol = length(colsdata2), nrow= 2) 
    params2 = as.data.frame(params2)
    rownames(params2) = c("Max", "Min")
    colnames(params2) = colsdata2
    
    # Defining the parameters of the spider plot
    
    params2[1,] = apply(select(outcome, colsdata2)[,colsdata2],2,max)
    params2[2,] = apply(select(outcome, colsdata2)[,colsdata2],2,min)
    
    # selection of hybrids to compare head to head
    values_hybrid <- reactive({
      selected <- input$selected_name  # Assuming this is your selectInput ID
      if (length(selected) > 0) {
        selected
      } else {
        # Default to the first 4 hybrids if none are selected
        outcome$hybrid[1:4]
      }
    })
    
    
    generate_spider_plot <- function(outcome, values_hybrid, colsdata2, params2, title) {
      # Filter and select data
      spider_plot2 <- outcome %>%
        filter(hybrid %in% values_hybrid) %>%
        select(colsdata2)
      
      # Add params row to the data
      spider_plot2 <- rbind(params2, spider_plot2)
      
      # Number of colours in the palette
      no_of_colors <- length(values_hybrid)
      
      # Applying the rainbow function
      colorful_palette <- rainbow(no_of_colors)
      
      # Plot settings
      par(mar = c(5, 4, 6, 9), xpd = TRUE)
      
      # Create the radar chart
      create_radarchart(spider_plot2, title = "Head to head - indexes", color = colorful_palette)
      
      # Add legend
      legend("topright", inset = c(0, 0), legend = values_hybrid, horiz = FALSE,
             bty = "n", pch = 20, col = colorful_palette,
             text.col = "black", cex = 1.2, pt.cex = 1.5)
    }
    
    # Render the spider plot
    output$hybrids_indexes <- renderPlot({
      generate_spider_plot(outcome, values_hybrid(), colsdata2, params2)
    })  
    
  })
}





# Run the application 
shinyApp(ui = ui, server = server)

