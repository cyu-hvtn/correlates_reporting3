###################################################################################################
# bootstrap marginalized risks
# type: 
#    1 for S=s
#    2 for S>=s
#    3 for categorical S
# data: ph1 data
# t: a time point near to the time of the last observed outcome will be defined

marginalized.risk.svycoxph.boot=function(marker.name, type, data, t, B, ci.type="quantile", numCores=1) {  
  # marker.name=a; type=3; data=dat.ph1; t=tfinal.tpeak; B=B; ci.type="quantile"; numCores=1
  
  # store the current rng state 
  save.seed <- try(get(".Random.seed", .GlobalEnv), silent=TRUE) 
  if (class(save.seed)=="try-error") {set.seed(1); save.seed <- get(".Random.seed", .GlobalEnv) } 
  
  data.ph2=subset(data, ph2==1)     
  
  if (comp.risk) {
    f1=lapply(form.0, function(x) update(x, as.formula(paste0("~.+",marker.name))))
  } else {
    f1=update(form.0, as.formula(paste0("~.+",marker.name)))        
  }
  
  # used in both point est and bootstrap
  # many variables are not passed but defined in the scope of marginalized.risk.svycoxph.boot
  fc.1=function(data.ph2, data, categorical.s, n.dean=FALSE){
    if (comp.risk) {
      # competing risk implementation
      newdata=data.ph2
      sapply(ss, function(x) {
        newdata[[marker.name]]=x
        risks = try(pcr2(f1, data.ph2, t, weights=data.ph2$wt, newdata=newdata))
        ifelse (inherits(risks, "try-error"), NA, weighted.mean(risks, data.ph2$wt))
      })
      
    } else {        
      # non-competing risk implementation
      result <- tryCatch({
        fit.risk.1=svycoxph(f1, design=twophase(id=list(~1,~1), strata=list(NULL,~Wstratum), subset=~ph2, data=data))
        out=marginalized.risk(fit.risk.1, marker.name, data.ph2, t=t, ss=ss, weights=data.ph2$wt, categorical.s=categorical.s)
        if (n.dean) {
          c(n.dean= last(coef(fit.risk.1)/sqrt(diag(fit.risk.1$var))) * sqrt(1/fit.risk.1$n + 1/fit.risk.1$nevent), out) 
        } else out
      }, 
      warning = function(w) {
        rep(NA, ifelse(n.dean,1,0)+length(ss))
      },
      error = function(e) {
        rep(NA, ifelse(n.dean,1,0)+length(ss))
      },
      finally = {
        # cat("This runs no matter what!\n")
      })
      result
      
    }           
  }
  
  fc.2=function(data.ph2){
    if (comp.risk) {
      sapply(ss, function(x) {
        newdata=data.ph2[data.ph2[[marker.name]]>=x, ]
        risks=try(pcr2(f1, newdata, t, weights=newdata$wt))
        ifelse (inherits(risks, "try-error"), NA, weighted.mean(risks, newdata$wt))
      })
      
    } else {
      # we don't try to catch warning here. if we do, all results are likely to to be NA
      # we could try to catch warning within the marginalized.risk.threshold call
      out = try(marginalized.risk.threshold (form.0, marker.name, data=data.ph2, weights=data.ph2$wt, t=t, ss=ss))
      if ( !inherits(out, "try-error" )) {
        out
      } else {
        rep(NA, length(ss)) 
      }

    }
  }    
  
  
  if (type==1) {
    # conditional on S=s (quantitative)
    # don't sort ss or do ss=ss[!duplicated(ss)] because e.g. 15% will be lost and later code depends on that
    ss=sort(c(
      # Lars quantiles so that to be consistent with his analyses, also add every 5% to include s1 and s2 for sensitivity analyses
      report.assay.values(data[[marker.name]][data$EventIndPrimary==1], marker.name.to.assay(marker.name)), 
      # 2.5% and 97.5% as the leftmost and rightmost points 
      wtd.quantile(data[[marker.name]], data$wt, c(0.025,0.05,0.95,0.975)),
      # equally spaced values so that the curves look good  
      seq(min(data[[marker.name]], na.rm=TRUE), max(data[[marker.name]], na.rm=TRUE), length=100)[-c(1,100)],
      # useful for reports
      if (log10(100)>min(data[[marker.name]], na.rm=TRUE) & log10(100)<max(data[[marker.name]], na.rm=TRUE)) log10(100)
    ))
    
    prob = fc.1(data.ph2, data, n.dean=TRUE, categorical.s=F)
    if (!comp.risk) {
      n.dean=prob[1]
      prob=prob[-1]
    } 
    
  } else if (type==2) {
    # conditional on S>=s
    # hack 0.9 to 0.5, otherwise lots of errors: No (non-missing) observations 
    ss=quantile(data[[marker.name]], seq(0,.5,by=0.05), na.rm=TRUE); if(verbose) myprint(ss)
    prob = fc.2(data.ph2)        
    
  } else if (type==3) {
    # conditional on S=s (categorical)
    ss=unique(data[[marker.name]]); ss=sort(ss[!is.na(ss)]); if(verbose) myprint(ss)        
    prob = fc.1(data.ph2, data, n.dean=F, categorical.s=T)
    
  } else if (type==4) {
    # conditional on S=s (quantitative)
    if (comp.risk) {
      stop("need to implement this (like type 1 but coef only)") 
    }else {
      tmp.design=twophase(id=list(~1,~1), strata=list(NULL,~Wstratum), subset=~ph2, data=data)
      fit.risk=try(svycoxph(f1, design=tmp.design)) # since we don't need se, we could use coxph, but the weights computed by svycoxph are a little different from the coxph due to fpc
    }
    
  } else stop("wrong type")
  
  # bootstrap
  if(config$sampling_scheme=="case_cohort") ptids.by.stratum=get.ptids.by.stratum.for.bootstrap (data)     
  seeds=1:B; names(seeds)=seeds
  out=mclapply(seeds, mc.cores = numCores, FUN=function(seed) {   
    seed=seed+560
    if (verbose>=2) myprint(seed)
    
    if (TRIAL=="moderna_boost") {
      dat.b = bootstrap.cove.boost.2(data, seed)
    } else if(config$sampling_scheme=="case_cohort") {
      dat.b = get.bootstrap.data.cor (data, ptids.by.stratum, seed) 
    } else if(TRIAL=="hvtn705") {
      dat.b = bootstrap.case.control.samples(data, seed, delta.name="EventIndPrimary", strata.name="tps.stratum", ph2.name="ph2") 
    } else stop("not sure which bootstrap function to use")
    
    dat.b.ph2=subset(dat.b, ph2==1)     
    
    if(type==1) {
      # conditional on s
      fc.1(dat.b.ph2, dat.b, categorical.s=F, n.dean=T)
      
    } else if (type==2) {
      # conditional on S>=s
      fc.2(dat.b.ph2)        
      
    } else if (type==3) {
      # conditional on a categorical S
      fc.1(dat.b.ph2, dat.b, n.dean=F, categorical.s=T)
      
    } else if (type==4) {
      # conditional on S=s (quantitative)
      fit.risk.b=try(svycoxph(f1, design=twophase(id=list(~1,~1), strata=list(NULL,~Wstratum), subset=~ph2, data=dat.b)))
      if ( class (fit.risk.b)[1] != "try-error" ) {
      } else {
        NA
      }
      
    } else stop("wrong type")
    
  })
  
  res=do.call(cbind, out)
  if (type==1 & !comp.risk) {
    # the first row is n.dean
    boot.n.dean=res[1,]
    res=res[-1,]
  }
  res=res[,!is.na(res[1,])] # remove NA's
  if (verbose) str(res)
  
  # restore rng state 
  assign(".Random.seed", save.seed, .GlobalEnv)    
  
  if (ci.type=="quantile") {
    ci.band=t(apply(res, 1, function(x) quantile(x, c(.025,.975), na.rm=T)))
  } else {
    stop("only quantile bootstrap CI supported for now")
  }
  
  ret = list(marker=if(type==3) names(prob) else ss, prob=prob, boot=res, lb=ci.band[,1], ub=ci.band[,2], if(type==1 & !comp.risk) n.dean=c(n.dean, boot.n.dean))   
  if (type==1 & !comp.risk) names(ret)[length(ret)]="n.dean" # this is necessary because when using if, that element won't have a name
  ret  
}    



# vaccine arm, conditional on continuous S=s
cat("get risks.all.1.Rdata\n")
if(!file.exists(paste0(save.results.to, "risks.all.1.Rdata"))) {    
  if (verbose) print("create risks.all.1")
  risks.all.1=lapply(all.markers, function (a) {
    if(verbose) myprint(a)
    marginalized.risk.svycoxph.boot(marker.name=a, type=1, data=dat.ph1, tfinal.tpeak, B=B, ci.type="quantile", numCores=numCores)                
  })
  save(risks.all.1, file=paste0(save.results.to, "risks.all.1.Rdata"))
  
} else {
  load(paste0(save.results.to, "risks.all.1.Rdata"))
}

  
# vaccine arm, conditional on S>=s
cat("get risks.all.2.Rdata\n")
if(!file.exists(paste0(save.results.to, "risks.all.2.Rdata"))) {    
  if (verbose) print("create risks.all.2")
  risks.all.2=lapply(all.markers, function (a) {
    if(verbose) myprint(a)
    marginalized.risk.svycoxph.boot(marker.name=a, type=2, data=dat.ph1, t=tfinal.tpeak, B=B, ci.type="quantile", numCores=numCores)        
  }) 
  save(risks.all.2, file=paste0(save.results.to, "risks.all.2.Rdata"))
  
} else {
  load(paste0(save.results.to, "risks.all.2.Rdata"))
}


# vaccine arm, conditional on categorical S
cat("get risks.all.3.Rdata\n")
if(!file.exists(paste0(save.results.to, "risks.all.3.Rdata"))) {    
  if (verbose) print("create risks.all.3")
  risks.all.3=lapply(all.markers, function (a) {
    if(verbose) myprint(a)
    marginalized.risk.svycoxph.boot(marker.name=a%.%"cat", type=3, data=dat.ph1, tfinal.tpeak, B=B, ci.type="quantile", numCores=numCores)                
  })    
  save(risks.all.3, file=paste0(save.results.to, "risks.all.3.Rdata"))
  
} else {
  load(paste0(save.results.to, "risks.all.3.Rdata"))
}

write(ncol(risks.all.1[[1]]$boot), file=paste0(save.results.to, "bootstrap_replicates"))
#rv$marginalized.risk.S.eq.s=list()
#for (a in assays) rv$marginalized.risk.S.eq.s[[a]] = risks.all.1[[a]][c("marker","prob")]
#rv$marginalized.risk.S.geq.s=list()
#for (a in assays) rv$marginalized.risk.S.geq.s[[a]] = risks.all.2[[a]][c("marker","prob")]

