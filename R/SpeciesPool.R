#' Species pool based on Beal's smoothing
#'
#' For each relevé, this function selects all neighbouring relevés having a similar potential species composition, and fits empirical non-linear functions to rarefaction curves.
#' @author Francesco Maria Sabatini
#' @author Helge Bruelheide
#' @param input.data data.frame of species abundances across relevés. It should have three columns: one with Relevé IDs, one with Species ID, and one with species abundance/cover values
#' @param coords Either a SpatialPointsDataFrame or a DataFrame with the geographic coordinates of all plots. If SpatialPointsDataframe, it should have Relevé IDs and areas defined in the data. If DataFrame, columns 1:2 should be coordinates (Long, Lat), columns 3:4 should be RelevèIDs and plot area, respectively.
#' @param Mij matrix of pairwise likelihood of species co-occurrence (sparse matrices accepted). If not provided, it will be calculated from the data
#' @param ncores integer indicating the number of cores to use. If ncores>1 the calculation will be done in parallel
#' @param rows a vector of integers indicating on which plots of the input.data the function should run
#' @param t.radius threshold of geographic buffer around target relevé
#' @param t.bray threshold of Bray-Curtis dissimilarity for selecting relevés compositionally similar to target relevé
#' @param t.plot.number minimum number of neighbouring relevés for calculating rarefaction curves
#' @param cutoff method used to estimate the size of the species pool. Default is 'iChao2', other possible are 'Gompertz' or 'Michaelis'
#' @param verbose logical
#' @param species.list logical: Should the list of species composing the species pool be returned?
#' @param mycrs a CRS object defining the coordinate reference of coords, if coords is a data.frame
#' @param lonlat Specify whether the CRS is projected (lonlat=T) or unprojected (lonlat=F)
#' @return Returns a dataframe containing for each relevé:
#' - Species -  the number of species observed across all relevés neighouring the target relevé\cr
#' - Chao, iChao2, jack1, jack2 -  various species richness estimates and standard errors, as derived from the function SpadeR::ChaoSpecies\cr
#' - nplots -  number of relevés within a t.radius distance from the target relevé having a bray-curtis dissimilarity lower than t.bray\cr
#' - beals.at.chao -  cut-off of Beals' occurrence likelihood, selected as the ith species corresponding to chao\cr
#' - n.plots.area -   number of relevés within a t.radius distance, and t.bray dissimilarity from target relevés for which area data is available\cr
#' - arr, gomp, mm, Asymp -   parameter estimates for different empirical non-linear functions fitted to rarefaction curves, with relative AIC\cr
#' - sp.pool.list -   list of species compatible with target relevé, i.e. having a Beals' likelihood lower than beals.at.chao\cr
#' @export
#' @examples



SpeciesPool <- function(input.data, coords, Mij=NULL, ncores=1, rows=NULL,
                              t.radius=20000, t.bray=0.2, t.plot.number=10L,
                        cutoff=c("iChao2", "Gompertz", "Michaelis"),
                        verbose=T, species.list=F, mycrs=NULL, lonlat=NULL) {

  ##validity check
  if(class(coords) != ("SpatialPointsDataFrame")) {
    if(class(mycrs) != "CRS") stop("object 'coords' should be of class 'SpatialPointsDataFrame, or a CRS should be provided")
    print(paste("Create SpatialPointsDataFrame with", mycrs))
    if(!is.numeric(coords[,4])) stop("Column 4 of object coords should be numeric, and contain plot areas")
    coords <- SpatialPointsDataFrame(coords = coords[,1:2],
                                     proj4string = mycrs,
                                     data = coords[,3:4])
  }
  if(is.null(lonlat)) stop("Please specify whether crs is project (lonlat=F) or unprojected (lonlat=T)")
  if(ncol(input.data) !=3) stop("input.data should have three columns: species, releve, abundance")
  colnames(input.data) <- c( "RELEVE_NR", "SPECIES_NR","COV_PERC")
  input.data$SPECIES_NR <- as.character(input.data$SPECIES_NR)
  input.data$RELEVE_NR <- as.character(input.data$RELEVE_NR)

  if(!is.numeric(input.data$COV_PERC)) {stop("The abundance column should be numeric")}
  if(any(tapply(input.data$COV_PERC, input.data$RELEVE_NR, "sum")==0)) {stop("There's a plot with no species")}

  if(ncol(coords@data)!=2) {stop("The coords object should have only two columns: ReleveID and PlotArea (besides the spatial coordinates)")}
  colnames(coords@data) <- c("RELEVE_NR", "AREA")
  coords@data$RELEVE_NR <- as.character(coords@data$RELEVE_NR)
  if(t.bray <0 | t.bray>1) stop("t.bray should be comprised between 0 and 1")
  #if(!is.numeric(t.plot.number)) stop("t.plot.number should be an integer number")
  if(length(cutoff)>1){
    cutoff <- "iChao2"
    if(verbose==T) {print("cutoff is not defined. Using default iChao2")}
  }
  if(!cutoff %in% c("iChao2", "Gompertz", "Michaelis")) stop("Valid cutoffs include: iChao2 (default), Gompertz, Michaelis")
  ## end of validity check

  #calculate Mij matrix, if it is not provided
  if(is.null(Mij)) {
    Mij <- Mij.calc(input.data)
    if(verbose) print("Mij matrix not specified - calculating it")
  }
  #all.species <- sort(unique(input.data$SPECIES_NR))
  all.species <- as.character(rownames(Mij))
#  if(!identical(all.species, as.numeric(colnames(Mij)))) {stop("check.order of species in Mij!")}
  if(any(!unique(input.data$SPECIES_NR) %in% all.species)) {stop("There a mismatch between species in Mij and species in input.data!")}

  DT <- input.data
  env <- coords


  ### select all rows if an index vector of plots is not specified
  if(is.null(rows)){
    rows <- 1:nrow(env)
  }

  if(ncores>1){
    if (verbose) print("Initialize parallel computing ...")
    clmax <- detectCores()
    if(ncores<clmax){
      cl <- makeCluster(ncores)
      registerDoParallel(cl)
      clusterEvalQ(cl = cl, expr = c(library('dismo'),
                                     library("dplyr"),
                                     library("tidyr"),
                                     library("reshape2"),
                                     library("SpadeR"),
                                     library("Matrix"),
                                     library("vegan")
      ))
      clusterExport(cl = cl, varlist = c("beals.all", "bray.curtis", "SAR.IIIb"))
    } else print("The ncores selected is higher than the number of available cores")
  }
  `%myinfix%` <- ifelse(ncores>1, `%dopar%`, `%do%`) # define if loop sequentially or in parallel


  if(verbose) print("Start main foreach loop")
  ##parallel starts
  result6 <- foreach(i = rows, .combine=rbind) %myinfix% {
  if(verbose) print(i)
    #set.seed(19)
    result <- array(NA, c(1,27), dimnames=list(NA,
                                               c("RELEVE_NR","Species" ,
                                                 "chao",   "chao.se",  "iChao2",   "iChao2.se",  "jack1",  "jack1.se", "jack2",    "jack2.se",
                                                 "n.plots","beals.at.chao","n.plots.area",
                                                 "arr.k","arr.z", "arr.AIC",
                                                 "gomp.Asym", "gomp.b2", "gomp.b3", "gomp.AIC",
                                                 "mm.Vm", "mm.K", "mm.AIC",
                                                 "Asymp", "R0.Asym", "lrc.Asym", "AIC.Asym"
                                                 #"t.radius", "t.bray", "t.plot.number"
                                                 )))
    result <- as_tibble(as.data.frame(result)) %>%
      mutate(RELEVE_NR=as.character(RELEVE_NR)) %>%
      mutate_at(.vars=vars(Species:AIC.Asym),
                .funs=~as.numeric(.))
    if(species.list==T) result <- result %>%
      mutate(sp.pool.list=NA) %>%
      mutate(sp.pool.list=as.list(sp.pool.list))

    #for(p in 1:nrow(parameters)){
    result[1,1] <- env@data$RELEVE_NR[i]
    #result[1,28] <- t.radius
    #result[1,29] <- t.bray
    #result[1,30] <- t.plot.number

    ## circle around the target plot
    circ <- circles(env[i, ], d = t.radius, lonlat = lonlat)
    poly <- circ@polygons
    options(warn=-1)
    proj4string(poly) <- proj4string(env)
    options(warn=0)
    index2 <- over(env,poly) ## check how many plots are in the surrounding
   # if(!is.na(index2[i])){  #THIS WORKAROUND avoids crashes when target plot is close to the day changing line
      # extract subset of env and DT
      env2 <- env[!is.na(index2),]
      #str(env2)
      if(dim(env2)[[1]]>=t.plot.number){
        DT2 <- DT %>%
          filter(RELEVE_NR %in% env2@data$RELEVE_NR)
        ### calculating DT.beals inside loop
        DT2.beals <-expand.grid(unique(DT2$RELEVE_NR), all.species) %>%
          as_tibble() %>%
          rename(RELEVE_NR=Var1, SPECIES_NR=Var2) %>%
          mutate_all(~as.character(.)) %>%
          left_join(DT2, by=c("RELEVE_NR", "SPECIES_NR")) %>%
          mutate(COV_PERC = replace_na(COV_PERC,0)) %>%
          mutate(COV_PERC=(COV_PERC>0)*1) %>%
          rename(presence=COV_PERC) %>%
          arrange(RELEVE_NR) %>%
          group_by(RELEVE_NR) %>%
          mutate(beals=beals.all(SPECIES_NR,presence, Mij))
        DT2.matrix.beals <- acast(DT2.beals, RELEVE_NR ~ SPECIES_NR, fill=0, value.var="beals")
        bray <- bray.curtis(DT2.matrix.beals,env@data$RELEVE_NR[i])
        index3 <- bray < t.bray
        # t.bray = threshold, below which plots are included
        index4 <- match(env2@data$RELEVE_NR, names(index3))

        env3 <- env2[index3[index4],]
        #str(env3)
        result[1,11] <- nrow(env3)  ### number of available plots
        if(dim(env3)[[1]]>=t.plot.number){
          DT3 <- DT2.beals %>%
            filter(RELEVE_NR %in% env3@data$RELEVE_NR)
          #take only a subsample of all available plots #  ==2*minimum threshold of plots
          if(dim(env3)[[1]]>=2*t.plot.number){
            subset3 <- c(env$RELEVE_NR[i], #keep original plot
                         sample(env3$RELEVE_NR[-which(env3$RELEVE_NR==env$RELEVE_NR[i])], 2*t.plot.number-1, replace=F)) ##sample additional plots
            DT3 <- DT3 %>%
              filter(RELEVE_NR %in% subset3)
            env3 <- env3[env3$RELEVE_NR %in% subset3,]
          }
          DT3.matrix <- acast(DT3, RELEVE_NR ~ SPECIES_NR, fill=0, value.var="presence")
          result[1,2] <- sum(colSums(DT3.matrix)>0)
          ### ADDED TRYCATCH to CHAOSPECIES as a workaround to avoid occasional crashes
          result[1,c(3:10)] <- tryCatch(t(as.numeric(t(ChaoSpecies(t(DT3.matrix),
                                                                 datatype="incidence_raw", k=10, conf=0.95)$Species_table[c(2,4,7:8),1:2]))),
                                        error = function(e){t(rep(NA, 8))}
          )
          if(!is.na(result[1,3])){
            target.plot <- DT3 %>% filter(RELEVE_NR==env@data$RELEVE_NR[i])
            result[1,12] <- sort(target.plot$beals, decreasing=T)[(round(result[1,3],0))$chao]  ##beals' at chao (not iChao!)
            # lowest beals probability of the species at value of chao
            ### Species area accumulation curves ###
            #env3@data$AREA
            # not all plots have an entry in the area field
            env4 <- env3 #[env3@data$AREA>0,]
            env4@data <- env4@data %>%
              filter(AREA>0)

            if(dim(env4)[[1]]>= t.plot.number){
              DT4 <- DT3[DT3$RELEVE_NR %in% env4@data$RELEVE_NR,]
              DT4.matrix <- acast(DT4, RELEVE_NR ~ SPECIES_NR, fill=0, value.var="presence")
              result[1,13] <- dim(DT4.matrix)[[1]]
              # n.plots.area

              ########## FMS additions #######
              ##### Type IIIb
              IIIb.out <- SAR.IIIb(DT4.matrix, env4@data$AREA, n=99)
              y <- IIIb.out$Pooled.Richness
              x1 <- IIIb.out$Sum.area
              ### Arrhenius
              model3b <- tryCatch(
                {
                  nls(y ~ SSarrhenius(x1, k, z))
                },
                error = function(e){
                  NA
                }
              )
              if (!is.na(model3b[1])){
                result[1,c(14:15)] <- t(coef(model3b))
                result[1,16] <- AIC(model3b)
              }
              ### Gompertz
              model3c <- tryCatch(
                {
                  b2 <- 0
                  nls(y ~ SSgompertz(x1, Asym, b2, b3))
                },
                error = function(e){
                  NA
                }
              )
              if (!is.na(model3c[1])){
                result[1,c(17:19)] <- t(coef(model3c))
                result[1,20] <- AIC(model3c)
              }
              ## MichaelisMenten
              model3d <- tryCatch(
                {
                  b2 <- 0
                  nls(y ~ SSmicmen(x1, Vm, K))
                },
                error = function(e){
                  NA
                }
              )
              if (!is.na(model3d[1])){
                result[1,c(21:22)] <- t(coef(model3d))
                result[1,23] <- AIC(model3d)
              }
              ## Asymptote model
              model3e <- tryCatch(
                {
                  nls(y ~ SSasymp(x1, Asym, R0, lrc))
                },
                error = function(e){
                  NA
                }
              )
              if (!is.na(model3e[1])){
                result[1,c(24:26)] <- t(coef(model3e))
                result[1,27] <- AIC(model3e)
              }
            }
            # store species pool in data table  #we do it out of the loop
            cutoff0 <- ifelse(cutoff=="iChao2", "iChao2",
                              ifelse(cutoff=="Gompertz", "gomp.Asym",
                                     "Asymp"))
            if(species.list==T & !is.na(as.numeric(result %>%
                                  dplyr::select(all_of(cutoff0)))) ){
                result <-  result %>%
                mutate(sp.pool.list = list(target.plot %>%
                                             ungroup() %>%
                                             arrange(desc(beals)) %>%
                                             slice(1:round(as.numeric(result[1,cutoff0][1]),0))
                                           ))
                                           #filter(beals >= (result[which(colnames(result)=="beals.at.chao")])$beals.at.chao )
            }


          }
        }

        #    }
      } else result[1,11] <- 0
      #  setTxtProgressBar(pb, i)
    return(result)
  }
  return(result6)
  stopCluster(cl)
}
